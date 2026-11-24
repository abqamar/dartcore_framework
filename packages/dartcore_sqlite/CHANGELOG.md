## 0.1.0

- SQLite adapter for `dartcore_db`, registered with `registerSqlite()`.
- File-based or `:memory:` databases; WAL and busy-timeout options.
- Pooled connections, transactions and savepoints through the shared `dartcore_db` pool.
- Passes the shared adapter contract suite used for PostgreSQL and MySQL.

First release.
