import 'package:dartcore_mssql/dartcore_mssql.dart';

import 'contract.dart';
import 'mssql_config.dart';

/// Needs a SQL Server (see mssql_config.dart). Skipped when none is reachable.
/// Not yet verified against a live server by the project.
void main() {
  runContract(
    EngineSpec(
      name: 'SQL Server',
      config: mssqlTestConfig(),
      idColumn: 'INT IDENTITY(1,1) PRIMARY KEY',
      boolType: 'BIT',
      timestampType: 'DATETIME2',
      dropIfExists: (t) => 'DROP TABLE IF EXISTS $t',
    ),
    register: () async => registerMssql(),
  );
}
