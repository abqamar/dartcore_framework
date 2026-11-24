import 'dart:async';

import 'package:dartcore_core/dartcore_core.dart';

import 'adapter.dart';
import 'config.dart';
import 'dialect.dart';
import 'pool.dart';
import 'results.dart';

/// Turns any [DriverConnection] opener into a pooled [DatabaseAdapter].
class PooledAdapter implements DatabaseAdapter {
  PooledAdapter(this.config, this._registration, {int? maxPoolSize})
    : _maxPoolSize = maxPoolSize ?? config.maxPoolSize;

  final ConnectionConfig config;
  final DriverRegistration _registration;
  final int _maxPoolSize;
  ConnectionPool<DriverConnection>? _pool;

  @override
  SqlDialect get dialect => _registration.dialect;
  @override
  AdapterCapabilities get capabilities => _registration.capabilities;

  PoolStats get stats =>
      _pool?.stats ?? const PoolStats(size: 0, idle: 0, inUse: 0, waiting: 0);

  ConnectionPool<DriverConnection> get _p =>
      _pool ??
      (throw ConnectionException(
        'Database is not connected. Call connect() first.',
      ));

  /// Opens the pool and one connection to fail fast on bad credentials.
  @override
  Future<void> connect() async {
    if (_pool != null) return;
    final pool = ConnectionPool<DriverConnection>(
      create: () => _open(),
      destroy: (c) => c.close(),
      validate: (c) async => c.isOpen && await c.ping(),
      maxSize: _maxPoolSize,
      idleTimeout: config.idleTimeout,
      acquireTimeout: config.acquireTimeout,
    );
    try {
      final first = await pool.acquire();
      pool.release(first);
    } catch (_) {
      await pool.close();
      rethrow;
    }
    _pool = pool;
  }

  Future<DriverConnection> _open() async {
    try {
      return await _registration.open(config).timeout(config.connectTimeout);
    } on TimeoutException catch (e) {
      throw ConnectionException(
        'Timed out connecting to ${config.host}:${config.port}.',
        cause: e,
        details: 'No response within ${config.connectTimeout.inSeconds}s.',
        hint:
            'Check the host and port, firewall or security-group rules, and '
            'whether the database server is reachable from here.',
      );
    }
  }

  @override
  Future<void> disconnect() async {
    final p = _pool;
    _pool = null;
    await p?.close();
  }

  Future<QueryResult> _run(DriverConnection c, CompiledQuery q) async {
    try {
      return await c.execute(q).timeout(config.queryTimeout);
    } on TimeoutException catch (e) {
      // The statement may still be running server-side; the connection state is
      // unknown, so the caller discards it.
      await c.close().catchError((_) {});
      throw QueryException(
        'Query timed out after ${config.queryTimeout.inSeconds}s.',
        sql: q.sql,
        cause: e,
      );
    }
  }

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    final pool = _p;
    final c = await pool.acquire();
    try {
      return await _run(c, query);
    } finally {
      pool.release(c, discard: !c.isOpen);
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseExecutor tx) action,
  ) async {
    final pool = _p;
    final c = await pool.acquire();
    final tx = _TxExecutor(this, c);
    var broken = false;
    try {
      await c.execute(CompiledQuery(dialect.beginSql));
      T result;
      try {
        result = await action(tx);
      } catch (_) {
        try {
          await c.execute(CompiledQuery(dialect.rollbackSql));
        } catch (_) {
          broken = true; // could not roll back: never reuse this connection
        }
        rethrow;
      } finally {
        tx.closed = true;
      }
      try {
        await c.execute(CompiledQuery(dialect.commitSql));
      } catch (_) {
        broken = true;
        rethrow;
      }
      return result;
    } finally {
      pool.release(c, discard: broken || !c.isOpen);
    }
  }

  @override
  Future<bool> ping() async {
    final pool = _pool;
    if (pool == null) return false;
    try {
      final c = await pool.acquire();
      var ok = false;
      try {
        ok = c.isOpen && await c.ping().timeout(config.queryTimeout);
      } finally {
        pool.release(c, discard: !ok);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }
}

class _TxExecutor implements DatabaseExecutor {
  _TxExecutor(this._adapter, this._conn);
  final PooledAdapter _adapter;
  final DriverConnection _conn;
  bool closed = false;

  @override
  Future<QueryResult> execute(CompiledQuery query) {
    if (closed) {
      throw DatabaseException(
        'This transaction has already finished; do not use it after the callback returns.',
      );
    }
    return _adapter._run(_conn, query);
  }
}
