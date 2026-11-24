# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No adapter registered for "postgres"` | Add `dartcore_postgres` and call `registerPostgres()` before `DB.connect`. |
| `No database connection. Call DB.connect(...) first.` | `DB.table()` ran before connecting, or after `DB.reset()`/`disconnect()`. |
| `ConnectionException: Timed out … waiting for a database connection` | Pool exhausted (`maxPoolSize`): long transactions, leaked work, or too much concurrency. Raise the pool or shorten work. Inspect `PooledAdapter.stats`. |
| `QueryException: Invalid identifier "…"` | A column/table contained characters outside `[A-Za-z0-9_$.]`; the builder rejects it on purpose. Use a raw API with bindings if you truly need it. |
| `QueryException: update() without a where()` | Add a `where`, or `allowAll: true` if you really mean every row. |
| `ILIKE is not supported by mysql` | PostgreSQL-only; use `like` (collation decides case sensitivity). |
| Responses show `Internal server error` only | Intended in production. Set `APP_ENV=development` (or `APP_DEBUG=true`) locally; the cause is always logged with the request id. |
| `Missing required configuration "JWT_SECRET"` / `JWT secret must be at least 32 bytes` | Set a real secret: `openssl rand -base64 48`. |
| `Auth is not configured` | Call `Auth.configure(AuthService(...))` before the first authenticated request (registering routes earlier is fine). |
| `Rule "unique" needs I/O; use Validate.requestAsync` | `unique`/`exists` are async-only; pass `exists: databaseExistenceChecker(...)`. |
| `Failed during migration …: Database query failed` | The failing statement's SQL is in `QueryException.sql` (inner `cause`). MySQL may have applied part of it (non-transactional DDL). |
| `Refusing to … without explicit confirmation` | Destructive migration API needs `confirm: true` / CLI `--force`. |
| `SQLite cannot modify a column in place` / `…add a UNIQUE or foreign-key column…` | SQLite limitation; recreate the table (create new, copy, drop, rename). |
| SQLite: queries block everything | `package:sqlite3` is synchronous; prefer PostgreSQL/MySQL for high-concurrency servers. |
| `dart compile exe` fails with build hooks | `sqlite3` needs `dart build`; see [deployment.md](deployment.md). |
| `dart pub get` fails for a generated project (`could not find package dartcore…`) | Packages aren't on pub.dev; create with `--path <checkout>` (adds the required `dependency_overrides`). |
| 413 Payload Too Large | Body over the limit; raise `AppConfig(limits: BodyLimits(...))` deliberately. |
| 504 from a route | Route/`requestTimeout` elapsed. The handler's work is not cancelled. |
| Port already in use | Another process owns `APP_PORT`; `dartcore serve --port N`. |
| Integration tests skip/fail to connect | `docker compose -f integration_tests/docker-compose.yml up -d postgres mysql`; ports 54329 / 33069. |
| Integration tests fail only when run together | They share databases; keep `integration_tests/dart_test.yaml` (`concurrency: 1`). |

## Reading database errors

`message` on a `DartCoreException` is deliberately generic (it is safe to show to API clients), for example `Database query failed (42P07).` or `Could not connect to PostgreSQL at localhost:5432.` The real reason is in two extra fields, printed by `toString()` and therefore by logs and uncaught-exception output:

```
QueryException: Database query failed (42P07).
  Details: [42P07] relation "users" already exists; table: users
  Hint: An object with this name already exists. If this ran as part of a migration, the migrations may have run partially, ...
```

* `details`: the driver's message plus SQLSTATE/error code, server detail, and table/column/constraint when known.
* `hint`: a one-sentence suggestion (for connection errors: refused, DNS failure, timeout, wrong credentials, missing database or role, SSL mismatch).
* `cause` still holds the original driver exception, and `QueryException.sql` the statement. Bound parameters and passwords are never included.
* `details` and `hint` are never written into HTTP responses; read them in the server log or console. `Failed during migration ...` errors carry the failing statement's `details` and `hint`.
* Careful: `details` can include data values from the server (for example `Key (email)=(a@b.c) already exists`). Treat logs accordingly.

