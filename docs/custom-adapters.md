# Custom database adapters

An adapter implements one interface, `DriverConnection`, and registers itself. Pooling, timeouts, transactions, savepoints and
the query builder come for free.

```dart
class MyConnection implements DriverConnection {
  @override bool get isOpen => ...;
  @override Future<bool> ping() async { ... }                 // SELECT 1
  @override Future<void> close() async { ... }
  @override
  Future<QueryResult> execute(CompiledQuery q) async {
    // q.sql uses the dialect's placeholders; q.bindings are positional, in order.
    // Bind natively. NEVER interpolate bindings into the SQL string.
    ...
    return QueryResult(rows: [...], affectedRows: n, insertId: id);
  }
}

void registerMyDb() => DatabaseManager.registerDriver(
      DatabaseDriver.mssql,                                   // or an existing/added enum value
      DriverRegistration(
        dialect: const MssqlDialect(),                        // or subclass SqlDialect
        capabilities: const AdapterCapabilities(returning: true),
        open: (config) async => MyConnection.open(config),
        poolSizeFor: (c) => c.maxPoolSize,                    // optional cap (e.g. 1 for in-memory DBs)
      ),
    );
```

Obligations (the contract suite checks them):

* Convert driver exceptions to `QueryException` (statement failed; put the SQL in `sql:`, **never** the bindings) or
  `ConnectionException` (connection broken). Keep driver messages in `cause`, not in `message`.
* Return plain Dart values: `int`/`double`/`String`/`bool`/`DateTime`(UTC)/`Uint8List`/`Map`/`List`. Convert `bool`, `DateTime`,
  `Map`/`List` *inputs* to what the driver accepts.
* `isOpen` must turn false when the connection dies so the pool discards it.
* If `dialect.supportsReturning`, `INSERT … RETURNING/OUTPUT` rows must come back in `rows`; otherwise report `insertId`.

Run the shared suite against your engine: copy `integration_tests/test/postgres_test.dart` and supply an `EngineSpec`
(connection, DDL spelling of `id`/boolean columns). Document anything unsupported in your compatibility table; do not emulate silently.

Dialect differences live in `SqlDialect` (quoting, placeholders, LIMIT/OFFSET, RETURNING, transaction/savepoint SQL, parameter limit).
