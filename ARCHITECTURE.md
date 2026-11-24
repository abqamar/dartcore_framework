# Architecture

## Layers

```
dartcore (umbrella: DartCore app, re-exports)
 ├─ dartcore_api ─────────── Router · Request · Response · Middleware · App lifecycle (Shelf inside)
 ├─ dartcore_auth ────────── AuthService · stores · Argon2id · sessions            (uses api, db)
 ├─ dartcore_orm ─────────── Model · relations · eager loading                     (uses db, validation)
 ├─ dartcore_migrations ──── SchemaBuilder · Migrator · Seeder · console           (uses db)
 ├─ dartcore_validation ──── rules engine                                          (uses core)
 ├─ dartcore_db ──────────── QueryBuilder · SqlCompiler · dialects · pool · manager (uses core)
 │    ▲  DriverConnection contract
 │    └─ dartcore_sqlite · dartcore_postgres · dartcore_mysql   (adapters)
 ├─ dartcore_cache ───────── CacheStore · MemoryCacheStore · cache-aside
 ├─ dartcore_logging ─────── Logger · handlers · redaction · request-id zones
 └─ dartcore_core ────────── exceptions · config · environment
```

Dependencies only point downwards; there are no cycles. `dartcore_core`, `dartcore_logging`, `dartcore_api` and
`dartcore_validation` work with no database. `dartcore_db` knows no driver. Adapters depend on `dartcore_db`, never the
reverse, so you install only the adapters you use and register them at startup (`registerPostgres()`).

## Database engine

```
DB.table('users') ──► QueryBuilder ──► SqlCompiler(dialect) ──► CompiledQuery(sql, bindings)
                                                                       │
Database / Transaction (DatabaseOperations)                            ▼
        │                                                    DatabaseAdapter  (PooledAdapter)
        ▼                                                          │ acquire/release
 DatabaseManager (named connections, default) ─────────────► ConnectionPool<DriverConnection>
                                                                       │
                                                          DriverConnection  ← implemented per driver
```

* **One pool for all adapters.** A driver implements only `DriverConnection` (`execute`, `ping`, `close`, `isOpen`).
  `PooledAdapter` provides pooling (max size, FIFO waiters, acquire/idle timeouts, health validation of idle connections,
  replacement of dead connections), query timeouts and transactions. This is why pool behaviour is identical and tested
  once (`pool_test.dart`), rather than depending on each driver's own pool.
* **Transactions** acquire a single connection, run `BEGIN`, hand the callback a connection-bound executor, then
  `COMMIT`/`ROLLBACK`. Nested `tx.transaction` uses `SAVEPOINT`. A connection that fails to roll back or commit is
  discarded, never reused. Using a transaction object after its callback returns throws.
* **Timeouts.** On a query timeout the statement may still run server-side, so the connection is closed and discarded.
* **Spec deviation:** the vision's `beginTransaction()/commit()/rollback()` on the adapter would let callers leak
  half-open transactions on a shared pool; the adapter exposes `transaction(callback)` instead.

## Global helpers vs instances

`DB`, `Config`, `Log`, `Cache` and `Auth` are thin static facades over a managed default instance that can be replaced
(`DB.use(manager)`) or reset (`DB.reset()`). The real objects (`DatabaseManager`, `ConfigRepository`, `Logger`,
`CacheRepository`, `AuthService`) are ordinary instances, so tests and multi-database apps never share state:
`DartCore(database: myManager)`. The only process-wide registry is the driver table filled by `registerX()`; it holds
stateless factories.

## HTTP pipeline

```
socket → Shelf handler → ExceptionMiddleware (always outermost)
       → RequestId + Logger  → global middleware (app.use order)
       → router dispatch → group middleware (outer→inner) → route middleware → [timeout] → handler
```

Responses travel back through the same chain in reverse. The exception middleware turns any thrown
`DartCoreException` into the standard envelope; for status ≥ 500 it returns only `"Internal server error"` (details only
when debug is on, which defaults to development only). See [API_DESIGN.md](API_DESIGN.md).

## Decisions and trade-offs

| Decision | Why | Cost |
|---|---|---|
| Explicit `toMap`/`fillFromMap` models, no reflection | `dart:mirrors` is unavailable in AOT; honest and fast | boilerplate (the CLI generates it); a codegen package is future work |
| Pub workspace instead of requiring Melos | Dart 3.6+ workspaces resolve the monorepo natively; Melos 7+ reads config from the root pubspec | contributors need Dart ≥ 3.10 |
| Own pool over drivers' pools | uniform, testable behaviour | one more component to maintain |
| Request body buffered once (default 1 MiB) | safe size limits, repeatable reads | no streaming request bodies; multipart (10 MiB) is held in memory |
| `insert()` returns the row | the vision's `Response.created(user)` | MySQL needs a second query |
| Raw SQL is a separate, named, advanced API | injection safety by default | users must opt in explicitly |
