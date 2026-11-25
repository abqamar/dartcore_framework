# How DartCore works

This page explains what happens inside a DartCore app: how a web request is handled, how a database call becomes SQL,
how the app starts and stops, and how it compiles into one binary. It is written for people who use the framework and
want to know what is going on, and for people who want to contribute.

Contents: [The packages](#1-the-packages) · [A request, step by step](#2-a-web-request-step-by-step) ·
[A database call](#3-a-database-call-step-by-step) · [One request, end to end](#4-one-request-end-to-end-post-apitasks) ·
[Startup and shutdown](#5-startup-and-shutdown) · [Compiling](#6-how-it-compiles-and-ships) ·
[Concurrency](#7-concurrency-and-scaling) · [Why it is built this way](#8-design-choices) · [Where to read the code](#9-where-to-read-the-code)

## 1. The packages

```
your code            routes, controllers, migrations, models
   │
dartcore_framework   one import; the `DartCore` class = HTTP app + database manager
   ├── dartcore_api          router, Request/Response, middleware, server lifecycle (Shelf inside)
   ├── dartcore_db           query builder, SQL compilers, connection pool, transactions
   │       └── adapters      dartcore_postgres | dartcore_mysql | dartcore_sqlite | dartcore_mssql   (register the one you use)
   ├── dartcore_validation   rule-based validation
   ├── dartcore_logging      structured logs, redaction, request ids
   └── dartcore_core         configuration (.env, environment) and exceptions

optional, add what you need:
   dartcore_migrations · dartcore_orm · dartcore_auth · dartcore_cache · dartcore_storage · dartcore_dashboard
and the tool:
   dartcore_cli          the `dartcore` command (create, make:*, migrate, doctor, build, deploy:init)
```

`DartCore` itself is tiny ([dartcore_app.dart](../packages/dartcore_framework/lib/src/dartcore_app.dart)): it is an `App`
(the HTTP part) plus a `DatabaseManager`, and it disconnects the database when the app shuts down. The framework works
without a database too: just never connect one.

Dependencies only point **downwards**. `dartcore_db` knows nothing about HTTP, and `dartcore_api` knows nothing about
databases. The umbrella package is where the two meet.

## 2. A web request, step by step

The code is in [`dartcore_api/lib/src/`](../packages/dartcore_api/lib/src) (`app.dart`, `router.dart`, `request.dart`,
`response.dart`, `middleware/`).

```
client ──HTTP──▶  dart:io HttpServer        started by shelf_io.serve(...) inside App.start()
                       │
                  _shelfHandler             turns Shelf's request into a DartCore Request
                       │
                  ┌────┴──────────────────────────────────────────────────────────────┐
                  │ ExceptionMiddleware        (outermost, always installed)          │
                  │  └ RequestIdMiddleware     adds / echoes X-Request-Id             │
                  │     └ LoggerMiddleware     "METHOD path status ms"                │
                  │        └ your app.use(...) middleware, in the order added         │
                  │           └ group middleware (outer group first)                  │
                  │              └ route middleware                                   │
                  │                 └ timeout (if the route has one) → your handler   │
                  └────┬──────────────────────────────────────────────────────────────┘
                       ▼
                  Response  ──back up through the same layers──▶ client
```

What each step does:

1. **Accept.** Dart's `HttpServer` takes the connection. Shelf is only used to run it; it never appears in your code or
   in DartCore's public API.
2. **Convert.** The Shelf request becomes a `Request`. The body is buffered **once**, so `json()` and `text()` can both be
   called. The limits (`BodyLimits`) are enforced from `Content-Length` and while reading: too big means `413`.
3. **Route.** The `Router` finds the handler by method and path. `:id` captures a segment, a trailing `*` captures the rest.
   A path that exists with the wrong method gets `405` with an `Allow` header, `OPTIONS` is answered automatically, and
   `HEAD` falls back to `GET`. Duplicate routes or names throw when you register them, not at request time.
4. **Middleware.** Each middleware receives the request and a `next` function. It can:
   - **answer early** (a rate limiter returns `429`, auth returns `401`) and never call `next`;
   - **call `next`**, then change the response on the way back (add a header, compress);
   - **put data on the request** (`request.attributes`) for later layers.
5. **Handler.** Your function runs and returns a `Response`. `Response.ok(map)` sends JSON as-is, `Response.success(data)`
   wraps it in the `{success, message, data, meta}` envelope, `Response.validationError(errors)` is a `422`.
6. **Errors.** Anything thrown becomes a response in `ExceptionMiddleware`. `ValidationException` is `422`,
   `AuthenticationException` `401`, `NotFoundException` `404`, and any other error is a generic `500`
   (`Internal server error`). The real cause is **logged with the request id**, never sent to the client in production.
7. **Observers.** `app.observe(...)` lets other code watch every request without being a middleware. The monitoring
   dashboard uses this to record endpoints and latencies.

## 3. A database call, step by step

The code is in [`dartcore_db/lib/src/`](../packages/dartcore_db/lib/src).

```
DB.table('tasks').where('user_id', 7).orderBy('id').get()
   │
   │  QueryBuilder             query_builder.dart   collects the query as DATA; nothing runs yet
   ▼
   SqlCompiler (per dialect)   compiler.dart + dialect.dart
   │     Postgres:  SELECT * FROM "tasks" WHERE "user_id" = $1 ORDER BY "id" ASC      bindings [7]
   │     MySQL:     SELECT * FROM `tasks` WHERE `user_id` = ? ORDER BY `id` ASC       bindings [7]
   ▼
   CompiledQuery(sql, bindings)
   │
   ▼
   PooledAdapter               pooled_adapter.dart + pool.dart
   │     takes a free connection from DartCore's own pool, or waits in a FIFO queue (acquireTimeout, default 30 s);
   │     checks an idle connection is still alive before reusing it; replaces dead ones
   ▼
   DriverConnection            the adapter you registered (dartcore_postgres → package:postgres → the server)
   │     runs the SQL with the bindings, returns rows
   ▼
   List<Map<String, Object?>>  engine-specific values are normalised (dates, numerics, JSON)
```

Things that follow from this design:

- **Safety is in the compile step**, in one place for every database. Values are always bound parameters. Identifiers
  (table and column names) are validated, then quoted. Operators come from a whitelist. `update` and `delete` refuse to
  run without a `where`. Anything invalid throws a `QueryException` instead of being silently dropped.
- **Dialects are data, not code paths in your app.** The same builder call compiles to `$1` placeholders for PostgreSQL
  and `?` for MySQL and SQLite. Things an engine cannot do (for example `ILIKE` outside PostgreSQL) throw instead of being
  emulated; see [DATABASE_COMPATIBILITY.md](../DATABASE_COMPATIBILITY.md).
- **Adapters are plug-ins.** `registerPostgres()` hands the `DatabaseManager` a `DriverRegistration`: a dialect, the
  engine's capabilities and a function that opens a connection. The core never imports a driver, so you install and
  compile only the one you use. Writing a new adapter means implementing `DriverConnection`
  ([custom-adapters.md](custom-adapters.md)).
- **One pool for everything.** All adapters use DartCore's own `ConnectionPool`, so timeouts, sizing, idle eviction and
  statistics behave the same on every database.
- **Transactions** pin one pooled connection for the whole callback. `DB.transaction((tx) async { ... })` commits when
  the callback returns and rolls back and rethrows when it throws; a nested `tx.transaction` becomes a `SAVEPOINT`.
  Always use `tx`, not `DB`, inside the callback, or that work happens outside the transaction.
- **Errors keep their cause.** A failed query or connection becomes a `QueryException` / `ConnectionException` whose
  `message` is safe for clients and whose `details` and `hint` say what went wrong (what the database reported, what to
  try). They appear in logs and the console, never in production HTTP responses.

`DB` is a static convenience over a default `DatabaseManager`. For tests or several databases, create your own
`DatabaseManager()` and pass it to `DartCore(database: manager)`; nothing in the framework requires the global.

## 4. One request, end to end: `POST /api/tasks`

This follows the request from the [tutorial](tutorial.md) through every layer.

```
curl -X POST https://api.example.com/api/tasks  -H "Authorization: Bearer <jwt>"  -d '{"title":"Write docs"}'
```

1. **Caddy** terminates TLS and forwards to `127.0.0.1:<APP_PORT>` with `X-Forwarded-For`. The API trusts that header only
   because `APP_TRUST_PROXY=true`.
2. **HttpServer → `_shelfHandler`** builds the `Request` and buffers the body (limit 1 MiB for JSON).
3. **Global middleware** runs: exception handling, request id, logging, `SecurityHeadersMiddleware`, the global
   `RateLimitMiddleware` (300 requests per minute per client IP).
4. **Router** matches `POST /api/tasks` inside the `/api` group.
5. **Group middleware** `Auth.middleware()` reads the bearer token, verifies the HS256 signature and expiry, checks the
   token has not been revoked, and loads the user. No token or a bad one answers `401` and the handler never runs.
6. **Handler** `TaskController.store`:
   - `await request.json()` parses the body (`400` if it is not a JSON object).
   - `Validate.request(body, rules)` checks `title`, `status` and the rest. On failure the handler returns
     `Response.validationError(...)`, a `422` with errors keyed by field.
   - `DB.table('tasks').insert({...v.validated, 'user_id': <from the token>, ...})`: `validated` holds only fields that
     have a rule, and `user_id` comes from the authenticated user, never from the request body.
7. **Database**: the builder compiles `INSERT INTO "tasks" (...) VALUES ($1, $2, ...) RETURNING *`, the pool lends a
   connection, PostgreSQL runs it, and the stored row comes back.
8. **Response** `Response.success(row, status: 201)` is JSON-encoded (timestamps as UTC ISO-8601), passes back through the
   middleware (security headers added, `X-Request-Id` echoed) and out through Caddy to the client.

## 5. Startup and shutdown

A typical `bin/server.dart`:

```dart
await Config.load();                                   // 1
registerPostgres();                                    // 2
await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));   // 3
final app = DartCore();                                // 4
app.use(const SecurityHeadersMiddleware());            // 5
registerRoutes(app);                                   // 6
await app.start();                                     // 7
```

1. `Config.load()` reads `.env`, then `.env.<APP_ENV>`; real environment variables win. Secrets can also come from a
   directory such as `/run/secrets`.
2. The adapter registers itself with the `DatabaseManager`.
3. The pool opens its first connection, so a wrong password or an unreachable server fails **here**, at startup, with a
   clear error, not on the first request.
4. `DartCore()` reads `APP_NAME`, `APP_ENV`, `APP_HOST`, `APP_PORT` and friends.
5. and 6. Middleware and routes are registered. Duplicate routes fail immediately.
7. `start()` binds the port and installs `SIGINT` and `SIGTERM` handlers.

**Shutdown** (Ctrl+C, or `systemctl stop`): the server stops accepting connections, lets in-flight requests finish for up
to `shutdownGracePeriod` (10 s), forces the rest closed, then runs the `onShutdown` hooks. `DartCore` registers one that
disconnects the database. The systemd unit that `dartcore deploy:init` writes allows 20 s before it kills the process.

## 6. How it compiles and ships

**In the repository** the packages form a [pub workspace](https://dart.dev/tools/pub/workspaces): every package has
`resolution: workspace`, so a single `dart pub get` at the root links them all to their local source.

**In your project**, `dart pub get` resolves `dartcore_framework` and the adapter you chose from pub.dev (or from git or
a path before the first release) and writes `.dart_tool/package_config.json`, a map from package name to folder. The
analyzer, `dart run` and the compiler all use that map.

**Compiling.** `dart compile exe bin/server.dart` does ahead-of-time (AOT) compilation:

```
bin/server.dart + your lib/ + dartcore_* + shelf + postgres + …   (everything reachable)
        │  unused code is removed (tree shaking)
        ▼
native executable, about 10 MB, with the Dart runtime inside      → runs with no Dart SDK installed
```

- **Cross-compiling:** `--target-os linux --target-arch x64` (or `arm64`) builds a Linux binary on your Mac. `dartcore build`
  does this, for the server and for the `console` binary that runs migrations, and puts them in `build/release/` with
  the deploy files.
- **No reflection.** A compiled Dart program cannot look at classes at runtime, so nothing here is discovered by
  scanning. Routes are registered in code, and models list their columns explicitly (the generator writes them).
- **The SQLite exception:** the `sqlite3` package needs a native build hook, which `dart compile exe` rejects. So
  `dartcore build` refuses SQLite projects. PostgreSQL and MySQL are pure Dart and compile fine. SQLite is still fine for
  development and tests (`dart run`, `dart test`).
- **Two binaries:** `server` serves requests; `console` runs commands (`migrate`, `db:seed`, `doctor`) against the same
  database settings. Deploys run `console migrate` once, as a step, not on every server start.

**Shipping** is: build on your machine, upload `build/release/`, run `install.sh` (creates a service user, installs the
binaries and a systemd unit, runs migrations when asked). The server needs only the database; see
[deployment.md](deployment.md).

## 7. Concurrency and scaling

- A process runs the server on **one Dart isolate**. Waiting for the network or the database does not block it, so many
  requests are in flight at once on a single thread.
- Work that **does** block it (heavy CPU, a synchronous driver such as SQLite) delays every other request while it runs.
  Keep handlers light; move heavy jobs elsewhere.
- To use more cores or for redundancy, run **several processes** behind a proxy. Then remember what is per process: the
  in-memory rate limiter, the in-memory cache and the in-memory auth stores. Use `DatabaseAuthStores` for tokens and
  sessions when you run more than one instance.
- Size the pool so `DB_POOL_MAX × number of processes` stays below the database's connection limit.
- There is no migration lock: run migrations from one place (the deploy step), not from every instance.

## 8. Design choices

| Choice | Why |
|---|---|
| Explicit models, no reflection or code generation required | AOT compilation has no reflection; explicit code is also easy to read and debug |
| Query builder that compiles to SQL + bindings | one place enforces injection safety for every database |
| Adapters as separate packages | you compile and ship only the driver you use |
| DartCore's own pool for every adapter | identical behaviour and tuning on every database |
| `message` safe for clients, `details`/`hint` for developers | helpful errors without leaking internals |
| Shelf hidden behind `Request`/`Response` | the HTTP layer can change without breaking your code |
| Static facades (`DB`, `Config`, `Log`, `Auth`) over replaceable instances | convenient in apps, replaceable in tests |
| Secure defaults (rotating refresh tokens, Argon2id, bound values, no `WHERE`-less writes) | the easy path is the safe path; see [SECURITY.md](../SECURITY.md) |

## 9. Where to read the code

| To understand | Read |
|---|---|
| the request pipeline | `dartcore_api/lib/src/app.dart`, `router.dart`, `middleware/` |
| requests and responses | `request.dart`, `response.dart` |
| watching requests | `observer.dart` (used by `dartcore_dashboard`) |
| query building and SQL | `dartcore_db/lib/src/query_builder.dart`, `compiler.dart`, `dialect.dart` |
| the pool, transactions, `DB` | `pool.dart`, `pooled_adapter.dart`, `manager.dart` |
| the adapter contract | `adapter.dart`, then `dartcore_postgres/lib/src/postgres_adapter.dart` as an example |
| configuration and exceptions | `dartcore_core/lib/src/config.dart`, `exceptions.dart` |
| authentication | `dartcore_auth/lib/src/auth.dart` |
| migrations | `dartcore_migrations/lib/src/` |
| the CLI and deploy tooling | `dartcore_cli/lib/src/runner.dart`, `deploy.dart`, `doctor.dart` |

More: [ARCHITECTURE.md](../ARCHITECTURE.md) (the design in depth) · [tutorial.md](tutorial.md) (build an API) ·
[database.md](database.md) · [http.md](http.md) · [middleware.md](middleware.md).
