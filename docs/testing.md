# Testing

## Your app

Test handlers without a socket via `app.send`:

```dart
final app = buildApp(manager);                         // see examples/complete_application/lib/app.dart
final res = await app.send('POST', '/users', body: {'name': 'Jo', 'email': 'jo@x.io'}, headers: {'authorization': 'Bearer …'});
expect(res.statusCode, 201);
expect(await res.readJson(), containsPair('success', true));
```

`send` runs the complete pipeline (exceptions, middleware, router). For a real socket use `await app.start(port: 0,
handleSignals: false)` and read `app.port`. `body` may be a `Map`/`List` (JSON), `String`, or bytes.

Isolation: create a `DatabaseManager()` per test (SQLite `:memory:` is perfect), pass it to `DartCore(database: manager)`,
and disconnect in `tearDown`. Avoid the global `DB` in library code so tests never share state; if you do use it,
`DB.use(DatabaseManager())` in `setUp` and `await DB.reset()` in `tearDown`. Silence logs with
`Logger(level: LogLevel.fatal, handlers: [])`.

## This repository

```bash
./scripts/test_all.sh                      # format check + analyzer + all packages + example + integration
dart test                                  # in any package directory
docker compose -f integration_tests/docker-compose.yml up -d postgres mysql
cd integration_tests && dart test          # adapters against real PostgreSQL 16 / MySQL 8.4 / SQLite
```

`integration_tests/test/contract.dart` is the **adapter contract**: the same 15 behaviours (CRUD, aggregates, where variants,
joins, pagination, type round-trips, injection inertness, commit/rollback, constraint errors, savepoints, error typing,
concurrency, bad credentials) run against every engine; `migrations_contract.dart` does the same for migrations. If the
database is not reachable the tests print how to start it and skip (CI provides the services, so a skip there is a failure
signal worth noticing). The integration suite is run serially (`dart_test.yaml`) because `migrate:fresh` drops every table.

Benchmarks: `cd benchmarks && dart run bin/bench.dart` (results from the reference machine in
[benchmark-results.txt](benchmark-results.txt); micro-benchmarks, JIT).
