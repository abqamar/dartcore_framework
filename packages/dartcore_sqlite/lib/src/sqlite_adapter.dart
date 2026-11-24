import 'dart:convert';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'sqlite_diagnostics.dart';

/// Registers the SQLite driver with [DatabaseManager]. Call once at startup.
///
/// Notes: `package:sqlite3` is synchronous, so queries run on the calling
/// isolate and block it for their duration. In-memory databases (`:memory:`)
/// are limited to a single pooled connection because each connection would
/// otherwise see a different, empty database.
void registerSqlite() {
  DatabaseManager.registerDriver(
    DatabaseDriver.sqlite,
    DriverRegistration(
      dialect: const SqliteDialect(),
      capabilities: const AdapterCapabilities(returning: true),
      open: SqliteConnection.open,
      poolSizeFor: (c) => _isMemory(c.database) ? 1 : c.maxPoolSize,
    ),
  );
}

bool _isMemory(String path) =>
    path == ':memory:' || path.isEmpty || path.startsWith('file::memory:');

class SqliteConnection implements DriverConnection {
  SqliteConnection._(this._db);

  final sql.Database _db;
  bool _open = true;

  static Future<DriverConnection> open(ConnectionConfig config) async {
    try {
      final db = _isMemory(config.database)
          ? sql.sqlite3.openInMemory()
          : sql.sqlite3.open(config.database);
      final busy = (config.options['busy_timeout_ms'] as int?) ?? 5000;
      db.execute('PRAGMA busy_timeout = $busy');
      db.execute('PRAGMA foreign_keys = ON');
      if (!_isMemory(config.database) && config.options['wal'] != false) {
        db.execute('PRAGMA journal_mode = WAL');
      }
      return SqliteConnection._(db);
    } on sql.SqliteException catch (e) {
      throw ConnectionException(
        'Could not open SQLite database "${config.database}".',
        cause: e,
        details: diagnoseSqliteError(
          resultCode: e.resultCode,
          message: e.message,
          explanation: e.explanation,
        ).details,
        hint: diagnoseSqliteOpenError(e.resultCode, config.database),
      );
    }
  }

  @override
  bool get isOpen => _open;

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    if (!_open) throw ConnectionException('SQLite connection is closed.');
    try {
      final params = query.bindings.map(_toSql).toList();
      final stmt = _db.prepare(query.sql);
      try {
        final rs = stmt.select(params);
        final names = rs.columnNames;
        final rows = [
          for (final r in rs)
            {for (var i = 0; i < names.length; i++) names[i]: r.columnAt(i)},
        ];
        // updatedRows is stale after read-only statements, so only trust it
        // for writes (including INSERT ... RETURNING).
        final wrote = !stmt.isReadOnly;
        return QueryResult(
          rows: rows,
          affectedRows: wrote ? _db.updatedRows : 0,
          insertId: wrote ? _db.lastInsertRowId : null,
        );
      } finally {
        stmt.close();
      }
    } on sql.SqliteException catch (e) {
      final d = diagnoseSqliteError(
        resultCode: e.resultCode,
        message: e.message,
        explanation: e.explanation,
      );
      throw QueryException(
        'Database query failed (SQLite ${e.resultCode}).',
        sql: query.sql,
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    }
  }

  @override
  Future<bool> ping() async {
    try {
      _db.select('SELECT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _db.close();
  }

  /// Converts Dart values into types SQLite can bind.
  static Object? _toSql(Object? v) {
    if (v == null || v is num || v is String || v is Uint8List) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is Map || v is List) return jsonEncode(v);
    return v.toString();
  }
}
