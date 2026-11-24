## 0.1.0

- Fluent `QueryBuilder`: select, where groups, joins, grouping, aggregates, insert, insertMany, update, increment, delete and pagination.
- SQL compilers (`SqlDialect`) for PostgreSQL, MySQL and SQLite; a SQL Server dialect compiles SQL but has no adapter.
- `DB` facade and `DatabaseManager` with named connections, `ConnectionConfig` (also from `DB_*` configuration keys).
- Connection pool with wait queue, idle eviction and validation of idle connections.
- Transactions with savepoints for nesting.
- Safety rules: bound values, validated identifiers, whitelisted operators, refusal of unscoped update and delete.

First release.
