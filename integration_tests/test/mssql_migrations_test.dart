import 'package:dartcore_mssql/dartcore_mssql.dart';

import 'migrations_contract.dart';
import 'mssql_config.dart';

/// Needs a SQL Server (see mssql_config.dart); drops every table in the test
/// database. Skipped when none is reachable. Not yet verified against a live server.
void main() => runMigrationContract(
  'SqlServer',
  mssqlTestConfig(),
  () async => registerMssql(),
);
