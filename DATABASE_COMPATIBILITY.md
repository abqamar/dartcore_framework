# Database compatibility

"Verified" means exercised by an automated test against the real engine in this repository
(`integration_tests/`, run via Docker). Anything else is labelled as such.

## Matrix

| Capability | SQLite | PostgreSQL | MySQL | SQL Server | Supabase |
|---|---|---|---|---|---|
| Adapter package | `dartcore_sqlite` | `dartcore_postgres` | `dartcore_mysql` | **none** | direct PG only |
| Underlying driver | `sqlite3` 3.9 (FFI) | `postgres` 3.6 | `mysql_dart` 4.0 | `mssql_connection` (FFI + FreeTDS) *evaluated* | `postgres` |
| Verified against a real server | ✅ (bundled SQLite) | ✅ PostgreSQL 16 | ✅ MySQL 8.4 | ❌ not run | ❌ not run |
| CRUD, joins, aggregates, pagination | ✅ | ✅ | ✅ | dialect compiles (unit-tested), not run | = PostgreSQL |
| Parameter binding | ✅ native | ✅ native (`$n`) | ✅ prepared (`?`) | dialect only | = PostgreSQL |
| Transactions + rollback | ✅ | ✅ | ✅ | dialect only | = PostgreSQL |
| Nested transactions (savepoints) | ✅ | ✅ | ✅ | dialect only (`SAVE TRANSACTION`) | = PostgreSQL |
| Connection pool | ✅ DartCore pool | ✅ DartCore pool | ✅ DartCore pool | – | = PostgreSQL |
| Query timeout | ⚠️ cannot interrupt a running statement (sync driver) | ✅ | ✅ | – | = PostgreSQL |
| `insert()` returns stored row | ✅ `RETURNING` | ✅ `RETURNING` | ⚠️ re-read by `insertId` | `OUTPUT INSERTED.*` (not run) | = PostgreSQL |
| Schema builder / migrations | ✅ | ✅ | ✅ (DDL not transactional) | DDL compiles (unit-tested) | = PostgreSQL |
| Modify column in place (`change()`) | ❌ throws `UnsupportedError` | ✅ | ✅ | compiles, not run | = PostgreSQL |
| Add UNIQUE / FK column to existing table | ❌ throws `UnsupportedError` | ✅ | ✅ | compiles, not run | = PostgreSQL |
| `ILIKE` | ❌ throws `QueryException` | ✅ | ❌ throws | ❌ throws | ✅ |
| `truncate()` | `DELETE FROM` (no autoincrement reset) | `TRUNCATE` | `TRUNCATE` | `TRUNCATE` | `TRUNCATE` |
| Streaming result sets | ❌ | ❌ | ❌ | ❌ | ❌ |

Nothing is silently emulated: an unsupported operation throws a typed exception that says why.

## Notes per engine

**SQLite.** `package:sqlite3` is synchronous, so a query blocks the isolate while it runs, and the query timeout cannot
interrupt a running statement (it still discards the connection afterwards). `:memory:` databases are limited to one pooled
connection, otherwise each connection would see a different empty database. File databases use WAL and a busy timeout. A
column that has an index cannot be dropped (SQLite rule).

**PostgreSQL.** Uses `package:postgres` v3 per pooled connection; pooling is DartCore's, so behaviour matches other
engines. `numeric` values are returned as `num` when parseable, otherwise as `String`. Maps/Lists bound as JSONB.

**MySQL.** `mysql_dart` returns DATETIME values as local-time `DateTime`s built from naive components; the adapter pins
sessions to UTC and re-tags results as UTC (found and fixed by the contract suite). MySQL implicitly commits DDL, so a
failing migration can be partially applied. MariaDB uses the same driver but is **not** tested here.

**SQL Server – feasibility spike result.** Checked `mssql_connection` 3.1.0, the only maintained candidate for Dart 3
(`dart_mssql` was last published in 2019 for Dart 2). Findings:
- It is **not pure Dart**: FFI over FreeTDS (`libsybdb`). Users must install FreeTDS (e.g. `brew install freetds`,
  `apt install libsybdb5`); the plugin bundles libraries for some platforms only.
- Parameterised queries use the native RPC path (`sp_executesql` + `dbrpcparam`), i.e. real binding. Its batch helper, however,
  substitutes escaped literals client-side, which DartCore would not use.
- Results come back as JSON strings, so type fidelity needs a per-type conversion layer.
- Transactions are `begin/commit/rollback` calls on one connection (compatible with DartCore's pool model).
- **Not verified**: FreeTDS is not installed in the development environment and installing system libraries was not
  authorised, so no adapter was written or run against a server (an Azure SQL Edge container is defined in
  `integration_tests/docker-compose.yml` for when it is). TLS and Windows/Kerberos auth are unknown.
- What *is* done and tested: `MssqlDialect` (brackets, `@pN`, `OFFSET … FETCH`, `OUTPUT INSERTED.*`, `SAVE TRANSACTION`,
  2100-parameter chunking) and MSSQL DDL compilation.
Decision: no `dartcore_mssql` package is shipped; the CLI refuses `--database mssql`.

**Supabase.** Direct PostgreSQL connection works through `dartcore_postgres` (`ssl: SslMode.require`) but was not tested
against a Supabase project. Supabase *services* (Auth, Storage, Realtime, PostgREST/RPC) are a separate integration that
is **not implemented**; `dartcore create --database supabase` generates the direct-connection setup only and says so in
the project README.

## Type conversion

| Dart → DB | SQLite | PostgreSQL | MySQL |
|---|---|---|---|
| `bool` | `1`/`0` | `boolean` | `1`/`0` |
| `DateTime` | UTC ISO-8601 text | `timestamp` | UTC `YYYY-MM-DD HH:MM:SS` |
| `Map` / `List` | JSON text | `jsonb` | JSON text |

Reading: booleans come back as `bool` (PostgreSQL) or `0`/`1` ints (SQLite/MySQL) — use `Casts.asBool` in models;
timestamps come back as UTC `DateTime` (PostgreSQL/MySQL) or ISO text (SQLite) — use `Casts.asDate`.
