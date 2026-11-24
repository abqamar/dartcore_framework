# Changelog

All notable changes are recorded here. DartCore follows semantic versioning from 1.0; 0.x may change between minors.

## Unreleased

### Added
* **Deployment without Docker.** `dartcore build` cross-compiles `server` and `console` binaries for Linux x64/arm64 (or the host) into `build/release/`;
  `dartcore deploy:init` writes a systemd unit, an nginx site and an idempotent `install.sh`; `dartcore doctor` checks `.env`, database, migrations, storage and port.
* `examples/tasks_api` (the tutorial application, with tests) and `docs/tutorial.md`.
* Per-package `README.md`, `CHANGELOG.md` and `example/` for every package; pub.dev metadata in every pubspec.

### Changed
* The umbrella package is now **`dartcore_framework`** (`import 'package:dartcore_framework/dartcore_framework.dart'`); the name `dartcore` is taken on pub.dev. The `dartcore` command-line tool and the `DartCore` class keep their names.
* Internal dependencies use `^0.1.0` instead of `any`, and `publish_to: none` was removed from the 16 packages.
* Generated projects: `late AuthService auth` is no longer `final` (so `configureAuth()` can run once per test), and long `if` statements use blocks so `dart format` keeps the analyzer clean.
* `docs/validation.md` documents that `validated` is a flat map keyed by rule path (nested and wildcard rules add dotted keys).

#### Database errors
* Database errors are no longer opaque. `DartCoreException` has new optional `details` (the real reason: driver message, table/column/constraint, SQLSTATE) and `hint` (one actionable sentence); `toString()` prints them on extra lines, so console/log output now shows e.g. `relation "users" already exists` instead of only `Database query failed (42P07)`. `message` is unchanged and `details`/`hint` are never sent in HTTP responses (apart from the existing development-only `debug` block, which prints `toString()`).
* `dartcore_postgres`, `dartcore_mysql`, `dartcore_sqlite` populate them for query and connect errors (connection refused, DNS, timeout, bad credentials, missing database/role, SSL). Passwords are never included.
* `Migrator` keeps `details`/`hint` when wrapping a failed migration.

## 0.1.0 – unreleased

First end-to-end version. Not published.

### Added
* `dartcore_core`: typed exceptions, layered configuration (`.env`, `.env.<env>`, process env, pluggable secret sources).
* `dartcore_logging`: structured logs, redaction, request-id correlation, console/file/memory handlers.
* `dartcore_api`: router (params, wildcards, groups, named routes, timeouts), request parsing (JSON/form/multipart with size limits),
  response helpers and envelope, middleware (CORS, rate limit, request id, logger, timing, security headers, maintenance,
  compression, exceptions), graceful shutdown.
* `dartcore_db`: query builder, SQL compilers for PostgreSQL/MySQL/SQLite/SQL Server, pool, transactions with savepoints,
  pagination, named connections, adapter contract.
* Adapters: `dartcore_sqlite`, `dartcore_postgres`, `dartcore_mysql` (verified against real servers).
* `dartcore_validation`, `dartcore_migrations`, `dartcore_orm`, `dartcore_auth`, `dartcore_cache`, `dartcore_cli`.
* Examples, integration contract suite, benchmarks, CI workflow, documentation.

### Known gaps
SQL Server adapter, Supabase services, Storage, OpenAPI, Redis cache — see [docs/status.md](docs/status.md).
