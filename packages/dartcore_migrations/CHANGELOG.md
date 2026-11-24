## 0.1.0

- `Migration` base class and `Migrator` (migrate, rollback, reset, fresh, status) tracking batches in a `dartcore_migrations` table.
- `Schema` / `SchemaBuilder` with column types, modifiers, indexes, foreign keys and alter operations for PostgreSQL, MySQL and SQLite.
- Each migration runs in a transaction where the engine supports transactional DDL (not MySQL).
- `Seeder` base class with `call` for nesting.
- `MigrationConsole` command runner with confirmation for destructive actions and a production guard.
- Unsupported engine features throw instead of being emulated.

First release.
