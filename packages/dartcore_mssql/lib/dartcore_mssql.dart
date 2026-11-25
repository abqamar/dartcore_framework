/// Microsoft SQL Server adapter for DartCore (experimental).
///
/// Call [registerMssql] once at startup, then connect with
/// `DB.connect(driver: DatabaseDriver.mssql, ...)`.
library;

export 'src/mssql_adapter.dart'
    show RawResult, RawRunner, SqlServerConnection, registerMssql;
export 'src/mssql_diagnostics.dart'
    show
        SqlServerDiagnosis,
        diagnoseSqlServerConnectError,
        diagnoseSqlServerQueryError;
