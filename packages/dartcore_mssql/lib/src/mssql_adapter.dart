import 'dart:convert';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:mssql_dart/mssql_dart.dart' as mssql;

import 'mssql_diagnostics.dart';

/// Registers the SQL Server driver with [DatabaseManager]. Call once at
/// startup, then `DB.connect(driver: DatabaseDriver.mssql, ...)`.
///
/// Built on the pure-Dart `mssql_dart` driver (no FreeTDS or ODBC, so programs
/// still compile to a single binary). DartCore's own pool manages one driver
/// connection per pooled connection, like every other adapter. `insert()`
/// returns the stored row through `OUTPUT INSERTED.*`.
///
/// **Experimental:** the dialect and the conversions are unit-tested, but this
/// adapter has not been run against a live SQL Server by the project; see the
/// package README.
void registerMssql() {
  DatabaseManager.registerDriver(
    DatabaseDriver.mssql,
    const DriverRegistration(
      dialect: MssqlDialect(),
      capabilities: AdapterCapabilities(returning: true),
      open: SqlServerConnection.open,
    ),
  );
}

/// Rows and the affected-row count of one command, already converted to plain
/// maps. The seam between this adapter and the driver, so the logic around it
/// can be tested without a server.
class RawResult {
  const RawResult(this.rows, this.affectedRows);
  final List<Map<String, Object?>> rows;
  final int affectedRows;
}

/// Runs [sql] with named [parameters] (`p1`, `p2`, ... matching `@p1`, `@p2`).
typedef RawRunner =
    Future<RawResult> Function(String sql, Map<String, Object?>? parameters);

class SqlServerConnection implements DriverConnection {
  SqlServerConnection._(mssql.MssqlConnection conn)
    : _conn = conn,
      _run = ((sql, parameters) async {
        final result = await conn.query(sql, parameters: parameters);
        return RawResult([
          for (final row in result) row.toColumnMap(),
        ], result.affectedRows);
      }),
      _isOpen = (() => conn.isOpen);

  /// For tests: builds a connection around a fake [run].
  SqlServerConnection.forTesting(
    RawRunner run, {
    bool Function()? isOpen,
    Future<void> Function()? onClose,
  }) : _conn = null,
       _run = run,
       _isOpen = (isOpen ?? () => true),
       _onClose = onClose;

  final mssql.MssqlConnection? _conn;
  final RawRunner _run;
  final bool Function() _isOpen;
  Future<void> Function()? _onClose;

  /// The driver settings for [config]. Public for tests.
  ///
  /// `ssl` maps to TLS like this: `disable` sends everything, including the
  /// login, **unencrypted**; `require` encrypts without verifying the server
  /// certificate (SQL Server commonly has a self-signed one); `verifyFull`
  /// verifies the chain and host name (use the `ca_file` option for your own CA).
  /// Other `options`: `instance` (named instance; then the port is looked up
  /// through the SQL Server Browser), `application_name`, `ca_file`,
  /// `trust_server_certificate`, `read_only_intent`.
  static mssql.MssqlConnectionSettings settingsFor(ConnectionConfig config) {
    final o = config.options;
    final instance = o['instance'] as String?;
    return mssql.MssqlConnectionSettings(
      host: config.host,
      port: instance == null ? config.port : null,
      instanceName: instance,
      username: config.username ?? '',
      password: config.password ?? '',
      database: config.database,
      applicationName: o['application_name'] as String? ?? 'dartcore',
      encrypt: config.ssl != SslMode.disable,
      trustServerCertificate:
          config.ssl == SslMode.require ||
          o['trust_server_certificate'] == true,
      caFile: o['ca_file'] as String?,
      connectTimeout: config.connectTimeout,
      readOnlyIntent: o['read_only_intent'] == true,
    );
  }

  static Future<DriverConnection> open(ConnectionConfig config) async {
    final settings = settingsFor(config);
    try {
      final conn = await mssql.MssqlConnection.connect(settings);
      return SqlServerConnection._(conn);
    } on Object catch (e) {
      final server = e is mssql.DatabaseException ? e : null;
      final d = diagnoseSqlServerConnectError(
        e,
        host: config.host,
        port: settings.port,
        database: config.database,
        username: config.username,
        password: config.password,
        number: server?.number,
        message: server?.text ?? (e is mssql.MssqlException ? e.message : null),
      );
      throw ConnectionException(
        'Could not connect to SQL Server at ${config.host}:${settings.port ?? config.port}.',
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    }
  }

  @override
  bool get isOpen => _isOpen();

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    try {
      final params = query.bindings.isEmpty
          ? null
          : <String, Object?>{
              for (var i = 0; i < query.bindings.length; i++)
                'p${i + 1}': toParameter(query.bindings[i]),
            };
      final res = await _run(query.sql, params);
      return QueryResult(
        rows: [
          for (final row in res.rows)
            {for (final e in row.entries) e.key: fromValue(e.value)},
        ],
        affectedRows: res.affectedRows < 0 ? 0 : res.affectedRows,
      );
    } on mssql.MssqlTimeoutException catch (e) {
      throw QueryException(
        'Query timed out.',
        sql: query.sql,
        cause: e,
        details: e.message,
        hint:
            'The statement ran longer than the command timeout. Check for '
            'locks (blocking sessions) and missing indexes.',
      );
    } on mssql.MssqlCancelledException catch (e) {
      throw QueryException(
        'Query was cancelled.',
        sql: query.sql,
        cause: e,
        details: e.message,
      );
    } on mssql.DatabaseException catch (e) {
      // Operational errors with number 0 come from the driver or the network
      // (the server never answered), not from the SQL.
      if (e is mssql.OperationalException && e.number == 0) {
        throw _connectionLost(e, e.text);
      }
      final d = diagnoseSqlServerQueryError(
        number: e.number,
        text: e.text,
        severity: e.severity,
        state: e.state,
      );
      throw QueryException(
        'Database query failed (SQL Server ${e.number}).',
        sql: query.sql,
        code: e.number.toString(),
        cause: e,
        details: d.details,
        hint: d.hint,
      );
    } on mssql.DataException catch (e) {
      throw QueryException(
        'Database query failed (invalid value).',
        sql: query.sql,
        cause: e,
        details: e.message,
        hint:
            'A parameter could not be converted to its SQL Server type '
            '(for example a number out of range, or text outside the code page).',
      );
    } on mssql.InterfaceException catch (e) {
      throw _connectionLost(e, e.message);
    }
  }

  ConnectionException _connectionLost(
    Object cause,
    String details,
  ) => ConnectionException(
    'SQL Server connection error.',
    cause: cause,
    details: details,
    hint:
        'The connection to SQL Server was lost or is unusable. Check the '
        'server, the network and any idle-connection timeouts on a firewall.',
  );

  @override
  Future<bool> ping() async {
    try {
      await _run('SELECT 1', null);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _conn?.close();
      await _onClose?.call();
    } catch (_) {}
  }

  /// Dart value to a driver parameter. Strings go to SQL Server as `nvarchar`,
  /// so comparing against a `varchar` column converts it and may skip an index.
  static Object? toParameter(Object? v) {
    if (v == null ||
        v is num ||
        v is String ||
        v is bool ||
        v is Uint8List ||
        v is BigInt ||
        v is Duration) {
      return v;
    }
    // `datetime2` keeps the calendar fields as given: send UTC fields.
    if (v is DateTime) return v.isUtc ? v : v.toUtc();
    if (v is Map || v is List) return jsonEncode(v);
    return v.toString();
  }

  /// Driver value to a plain Dart value.
  static Object? fromValue(Object? v) {
    if (v == null ||
        v is bool ||
        v is num ||
        v is String ||
        v is Uint8List ||
        v is DateTime ||
        v is Duration ||
        v is BigInt) {
      return v;
    }
    if (v is mssql.DecimalValue) {
      // Exact for up to 15-16 digits; larger values stay text so nothing is
      // silently rounded.
      final fits = v.unscaledValue.abs() <= BigInt.from(9007199254740991);
      if (!fits) return v.toString();
      return v.scale == 0
          ? v.unscaledValue.toInt()
          : double.parse(v.toString());
    }
    if (v is mssql.DateTimeOffsetValue) return v.utc;
    return v.toString();
  }
}
