import 'dart:io';

import 'package:dartcore_db/dartcore_db.dart';

/// Connection settings for the SQL Server suites. Defaults match the
/// `mssql` service in docker-compose.yml (Azure SQL Edge); override with
/// MSSQL_HOST, MSSQL_PORT, MSSQL_DATABASE, MSSQL_USERNAME, MSSQL_PASSWORD,
/// MSSQL_SSL (disable|require|verify-full) to use any other SQL Server.
///
/// The suites drop every table in the database (the migrations suite runs
/// `migrate:fresh`), so the database name must contain "test"; anything else
/// is refused. Create it first: `CREATE DATABASE dartcore_test`.
ConnectionConfig mssqlTestConfig() {
  final env = Platform.environment;
  final database = env['MSSQL_DATABASE'] ?? 'dartcore_test';
  if (!database.toLowerCase().contains('test')) {
    throw StateError(
      'Refusing to run the SQL Server suites against "$database": they drop '
      'every table. Use a database whose name contains "test".',
    );
  }
  return ConnectionConfig(
    driver: DatabaseDriver.mssql,
    host: env['MSSQL_HOST'] ?? '127.0.0.1',
    port: int.tryParse(env['MSSQL_PORT'] ?? '') ?? 14339,
    database: database,
    username: env['MSSQL_USERNAME'] ?? 'sa',
    password: env['MSSQL_PASSWORD'] ?? 'DartCore_Passw0rd',
    ssl: switch ((env['MSSQL_SSL'] ?? 'require').toLowerCase()) {
      'disable' => SslMode.disable,
      'verify-full' => SslMode.verifyFull,
      _ => SslMode.require,
    },
    connectTimeout: const Duration(seconds: 5),
    maxPoolSize: 5,
  );
}
