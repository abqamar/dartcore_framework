## 0.1.0

- Microsoft SQL Server adapter for `dartcore_db`, registered with `registerMssql()`.
- Built on the pure-Dart `mssql_dart` driver: no FreeTDS or ODBC, so programs still compile to one native binary.
- Pooled connections (DartCore's pool), transactions with `SAVE TRANSACTION` savepoints, `OUTPUT INSERTED.*` for `insert()`.
- Values are always bound as named parameters (`@p1`, `@p2`, ...); dates are sent and returned as UTC.
- Real reasons and hints for query and connection failures (error numbers such as 2627, 208, 18456).
- **Experimental:** unit-tested (conversion, error mapping, settings, and a real connect to a closed port), but not yet verified against a live SQL Server.

First release.
