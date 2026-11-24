import 'dart:convert';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:postgres/postgres.dart' as pg;

import 'postgres_diagnostics.dart';

/// Registers the PostgreSQL driver with [DatabaseManager]. Call once at
/// startup. Pooling is provided by DartCore's own pool (one `pg.Connection`
/// per pooled connection) so behaviour matches every other adapter.
///
/// Also works for Supabase-hosted Postgres via a direct connection string
/// (use `ssl: SslMode.require`). Supabase *services* live in
/// `dartcore_supabase`, not here.
void registerPostgres() {
  DatabaseManager.registerDriver(
    DatabaseDriver.postgres,
    const DriverRegistration(
      dialect: PostgresDialect(),
      capabilities: AdapterCapabilities(returning: true),
      open: PostgresConnection.open,
    ),
  );
}

class PostgresConnection implements DriverConnection {
  PostgresConnection._(this._conn);

  final pg.Connection _conn;

  static Future<DriverConnection> open(ConnectionConfig config) async {
    try {
      final conn = await pg.Connection.open(
        pg.Endpoint(
          host: config.host,
          port: config.port ?? 5432,
          database: config.database,
          username: config.username,
          password: config.password,
        ),
        settings: pg.ConnectionSettings(
          sslMode: switch (config.ssl) {
            SslMode.disable => pg.SslMode.disable,
            SslMode.require => pg.SslMode.require,
            SslMode.verifyFull => pg.SslMode.verifyFull,
          },
          connectTimeout: config.connectTimeout,
          applicationName:
              config.options['application_name'] as String? ?? 'dartcore',
        ),
      );
      return PostgresConnection._(conn);
    } on Exception catch (e) {
      final d = diagnosePostgresConnectError(
        e,
        host: config.host,
        port: config.port ?? 5432,
        database: config.database,
        username: config.username,
        password: config.password,
      );
      throw ConnectionException(
        'Could not connect to PostgreSQL at ${config.host}:${config.port}.',
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    }
  }

  @override
  bool get isOpen => _conn.isOpen;

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    try {
      final result = await _conn.execute(
        query.sql,
        parameters: query.bindings.isEmpty
            ? null
            : query.bindings.map(_toPg).toList(),
      );
      final names = [for (final c in result.schema.columns) c.columnName ?? ''];
      final rows = [
        for (final r in result)
          {for (var i = 0; i < names.length; i++) names[i]: _fromPg(r[i])},
      ];
      return QueryResult(rows: rows, affectedRows: result.affectedRows);
    } on pg.ServerException catch (e) {
      final d = diagnosePostgresServerException(e);
      throw QueryException(
        'Database query failed (${e.code ?? 'error'}).',
        sql: query.sql,
        code: e.code,
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    } on pg.PgException catch (e) {
      throw ConnectionException(
        'PostgreSQL connection error.',
        cause: e,
        details: e.message,
        hint:
            'The connection to Postgres was lost or is unusable. Check the '
            'server logs and network.',
      );
    }
  }

  @override
  Future<bool> ping() async {
    try {
      await _conn.execute('SELECT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() => _conn.close();

  static Object? _toPg(Object? v) {
    if (v is Map || v is List<Object?> && v is! Uint8List) {
      return pg.TypedValue(pg.Type.jsonb, v);
    }
    return v;
  }

  /// Converts driver-specific types to plain Dart values.
  static Object? _fromPg(Object? v) {
    if (v == null || v is num || v is String || v is bool || v is DateTime) {
      return v;
    }
    if (v is Uint8List) return v;
    if (v is pg.UndecodedBytes) {
      return utf8.decode(v.bytes, allowMalformed: true);
    }
    if (v is Map || v is List) return v;
    // numeric/decimal and other exotic types: prefer a number, else text.
    final s = v.toString();
    return num.tryParse(s) ?? s;
  }
}
