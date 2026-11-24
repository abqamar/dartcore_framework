# Query builder

```dart
final users = await DB.table('users')
    .select(['id', 'name'])
    .where('status', 'active')              // = by default
    .where('age', '>=', 18)
    .orderBy('created_at', descending: true)
    .limit(20)
    .get();                                  // List<Map<String, Object?>>
```

The builder is mutable and returns itself; `clone()` branches. Nothing runs until a terminal call.

| Group | Methods |
|---|---|
| select | `select([cols])` `selectAll()` `distinct()` `selectRaw(expr)` *(advanced)* |
| where | `where` `orWhere` `whereIn` `whereNotIn` `whereNull` `whereNotNull` `whereBetween` `whereLike` `whereGroup` `orWhereGroup` `whereRaw` *(advanced)* `when(cond, fn)` |
| joins | `join`/`innerJoin` `leftJoin` `rightJoin` – `(table, firstCol, op, secondCol)` |
| shaping | `orderBy` `orderByAllowed` `groupBy` `having` `havingRaw` `limit` `offset` |
| read | `get` `first` `find(id)` `count` `exists` `sum` `avg` `min` `max` `paginate(page:, limit:)` |
| write | `insert(map)` → stored row · `insertMany(list)` → count · `update(map)` · `increment`/`decrement` · `delete()` · `truncate()` |

Behaviours worth knowing:

* `where('deleted_at', null)` becomes `IS NULL`; `where('x', '!=', null)` becomes `IS NOT NULL`.
* `whereIn('id', [])` is `1 = 0` (and `whereNotIn` with `[]` is `1 = 1`): never invalid SQL, never silently dropped.
* `update`, `increment`, `delete` **refuse to run without a `where`** unless `allowAll: true`.
* `insertMany` requires identical keys in every row and splits into several statements to stay under each engine's
  parameter limit; wrap it in a transaction for all-or-nothing.
* `insert` returns the stored row on PostgreSQL/SQLite/SQL Server; on MySQL it re-reads by `insertId` (or returns your input).
* `count()` of a `distinct`/`groupBy`/`limit` query counts the result set (subquery).

```dart
// conditions
DB.table('users').where('active', true).when(search != null, (q) => q.where('name', 'like', '%$search%'));
DB.table('users').where('active', true).whereGroup((q) {
  q.where('role', 'admin');
  q.orWhere('role', 'manager');
});                                          // ... AND (role = ? OR role = ?)

// pagination
final page = await DB.table('users').orderBy('id').paginate(page: 2, limit: 20);
page.data; page.currentPage; page.perPage; page.total; page.lastPage; page.hasNextPage; page.hasPreviousPage; page.meta;
return Response.success(page.data, meta: page.meta);

// request-driven sorting: ALWAYS whitelist
DB.table('users').orderByAllowed(request.query('sort'), ['id', 'name', 'created_at'], fallback: 'id');
```

## Safety rules the builder enforces

Values are bound parameters; identifiers are validated (`letters, digits, _, $` with dots) then quoted; operators are
whitelisted; invalid input throws `QueryException` rather than being ignored. Raw APIs exist for what the builder cannot
express — use `?` placeholders with a bindings list. See [SECURITY.md](../SECURITY.md).

`ILIKE` works only on PostgreSQL and throws elsewhere (no silent emulation). `like` case-sensitivity follows the database collation.
