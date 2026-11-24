import 'dart:convert';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart' as my;

import 'mysql_diagnostics.dart';

/// Registers the MySQL driver with [DatabaseManager]. Call once at startup.
///
/// DartCore's own pool manages one `MySQLConnection` per pooled connection.
/// MySQL has no `RETURNING`; `insert()` re-reads the row by `insertId`.
void registerMySql() {
  DatabaseManager.registerDriver(
    DatabaseDriver.mysql,
    const DriverRegistration(
      dialect: MySqlDialect(),
      capabilities: AdapterCapabilities(returning: false),
      open: MySqlConnection.open,
    ),
  );
}

class MySqlConnection implements DriverConnection {
  MySqlConnection._(this._conn);

  final my.MySQLConnection _conn;

  static Future<DriverConnection> open(ConnectionConfig config) async {
    try {
      final conn = await my.MySQLConnection.createConnection(
        host: config.host,
        port: config.port ?? 3306,
        userName: config.username ?? '',
        password: config.password ?? '',
        databaseName: config.database,
        secure: config.ssl != SslMode.disable,
        verifyServerCertificate: config.ssl == SslMode.verifyFull,
        allowPublicKeyRetrieval:
            config.options['allow_public_key_retrieval'] == true,
      );
      await conn.connect(timeoutMs: config.connectTimeout.inMilliseconds);
      // Predictable behaviour: strict SQL mode and UTC timestamps.
      await conn.execute(
        "SET SESSION sql_mode = CONCAT(@@sql_mode, ',STRICT_ALL_TABLES')",
      );
      await conn.execute("SET time_zone = '+00:00'");
      return MySqlConnection._(conn);
    } on Exception catch (e) {
      final d = diagnoseMySqlConnectError(
        e,
        host: config.host,
        port: config.port ?? 3306,
        database: config.database,
        username: config.username,
        password: config.password,
        errorCode: e is MySQLServerException ? e.errorCode : null,
        message: e is MySQLException ? e.message : null,
      );
      throw ConnectionException(
        'Could not connect to MySQL at ${config.host}:${config.port}.',
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    }
  }

  @override
  bool get isOpen => _conn.connected;

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    try {
      final res = await _conn.execute(
        query.sql,
        query.bindings.isEmpty ? null : query.bindings.map(_toMy).toList(),
      );
      final rows = [
        for (final r in res.rows)
          {for (final e in r.typedAssoc().entries) e.key: _fromMy(e.value)},
      ];
      final id = res.lastInsertID;
      return QueryResult(
        rows: rows,
        affectedRows: res.affectedRows.toInt(),
        insertId: id == BigInt.zero ? null : id.toInt(),
      );
    } on MySQLServerException catch (e) {
      final d = diagnoseMySqlQueryError(
        errorCode: e.errorCode,
        message: e.message,
      );
      throw QueryException(
        'Database query failed (MySQL ${e.errorCode}).',
        sql: query.sql,
        code: e.errorCode.toString(),
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    } on MySQLException catch (e) {
      throw ConnectionException(
        'MySQL connection error.',
        cause: e,
        details: e.message,
        hint:
            'The connection to MySQL was lost or is unusable. Check the '
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
  Future<void> close() async {
    try {
      await _conn.close();
    } catch (_) {}
  }

  /// The driver builds DATETIME/TIMESTAMP values from naive components as
  /// local-time `DateTime`s. Sessions are pinned to UTC, so re-tag as UTC.
  static Object? _fromMy(Object? v) => v is DateTime && !v.isUtc
      ? DateTime.utc(
          v.year,
          v.month,
          v.day,
          v.hour,
          v.minute,
          v.second,
          v.millisecond,
          v.microsecond,
        )
      : v;

  static Object? _toMy(Object? v) {
    if (v == null || v is num || v is String || v is Uint8List) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is DateTime) {
      return v
          .toUtc()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .replaceFirst('Z', '');
    }
    if (v is Map || v is List) return jsonEncode(v);
    return v.toString();
  }
}
