# Package structure

```
dartcore_framework/
├── pubspec.yaml            Pub workspace root (+ Melos 7 config); every package has `resolution: workspace`
├── analysis_options.yaml   strict-casts, strict-raw-types, lints/recommended + a few rules
├── packages/
│   ├── dartcore_framework/    umbrella: DartCore app, DB-backed validation, re-exports
│   ├── dartcore_core/         exceptions, config, environment
│   ├── dartcore_logging/      logger, handlers, redaction
│   ├── dartcore_api/          router, request, response, middleware, app
│   ├── dartcore_db/           query builder, compiler, dialects, pool, manager, adapter contract
│   ├── dartcore_sqlite/       adapter
│   ├── dartcore_postgres/     adapter
│   ├── dartcore_mysql/        adapter
│   ├── dartcore_validation/   rules engine
│   ├── dartcore_migrations/   schema builder, migrator, seeders, console
│   ├── dartcore_orm/          models, relations
│   ├── dartcore_auth/         JWT, refresh rotation, Argon2id, RBAC, sessions, DB stores
│   ├── dartcore_cache/        memory cache + facade
│   └── dartcore_cli/          `dartcore` executable
├── examples/
│   ├── basic_api/             no database
│   └── complete_application/  users, products, auth, CRUD, validation, pagination (PostgreSQL/SQLite) + tests
├── integration_tests/         adapter + migration contract suites, docker-compose for PostgreSQL/MySQL/SQL Server
├── benchmarks/                micro-benchmarks
├── docs/                      guides, status, benchmark results
├── scripts/test_all.sh
└── .github/workflows/ci.yml
```

Differences from the original proposal: no `dartcore_mssql`, `dartcore_supabase`, `dartcore_storage`, `dartcore_openapi`
packages yet (see [docs/status.md](docs/status.md)); a single `complete_application` example plus the CLI-generated projects
replaces the per-database example folders (each database is covered by `integration_tests`); no `melos.yaml` (Melos 7+ reads
the `melos:` key in the root `pubspec.yaml`).

## Dependency rules

* Arrows only point down the stack in [ARCHITECTURE.md](ARCHITECTURE.md); no cycles.
* `dartcore_core`, `dartcore_logging`, `dartcore_validation` have no database knowledge; `dartcore_db` has no driver knowledge.
* Public APIs never expose driver or Shelf types. Each package has one public barrel (`lib/<package>.dart`) and keeps
  implementation under `lib/src/`.
* Direct third-party dependencies: `shelf`, `mime` (api); `sqlite3`, `postgres`, `mysql_dart` (adapters); `crypto`,
  `cryptography`, `dart_jsonwebtoken` (auth); `args`, `path` (cli).

## Minimum Dart version

**Dart 3.10** (the `sqlite3` 3.x package requires it; Shelf 1.4 needs 3.9). Developed and tested on 3.13.4.
