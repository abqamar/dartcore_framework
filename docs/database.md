# Database configuration (PostgreSQL, MySQL, SQLite, SQL Server, Supabase)

```dart
registerPostgres();   // from dartcore_postgres   (registerMySql(), registerSqlite() likewise)

await DB.connect(
  driver: DatabaseDriver.postgres,
  host: 'localhost', port: 5432,
  database: 'my_database', username: 'postgres', password: 'password',
  ssl: SslMode.disable,                    // disable | require | verifyFull
  maxPoolSize: 10,
  connectTimeout: const Duration(seconds: 10),
  queryTimeout: const Duration(seconds: 30),
);
```

Or from configuration / an immutable object:

```dart
await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));            // DB_* keys
await DB.connectWith(const ConnectionConfig(driver: DatabaseDriver.mysql, database: 'app', username: 'root'));
```

## Multiple and named connections; instances

```dart
await DB.connect(driver: ..., database: 'main');                         // becomes the default
await DB.connect(driver: ..., database: 'analytics', name: 'analytics');
await DB.connection('analytics').table('events').get();

final manager = DatabaseManager();                  // isolated instance: tests, multi-tenant, libraries
await manager.connect(config);
final app = DartCore(database: manager);            // app.database.table('users').get()
await DB.reset();                                   // disconnect everything, fresh default manager
```

## Pool

Every adapter uses DartCore's pool: `maxPoolSize`, FIFO wait queue with `acquireTimeout` (default 30 s, then
`ConnectionException`), idle eviction (`idleTimeout`, default 5 min), validation of idle connections before reuse,
automatic replacement of dead connections, graceful `disconnect()`. `PooledAdapter.stats` exposes size/idle/in-use/waiting.
A timed-out query closes its connection (the server may still be running it).

## Per engine

* **PostgreSQL** – `dartcore_postgres`. `application_name` via `options: {'application_name': 'api'}`. Uses TLS when `ssl` is
  not `disable`.
* **MySQL** – `dartcore_mysql`. Sessions are set to strict mode and UTC. `options: {'allow_public_key_retrieval': true}` for
  servers needing RSA key retrieval without TLS (understand the risk first).
* **SQLite** – `dartcore_sqlite`. `database` is a path or `:memory:`; `options: {'wal': false, 'busy_timeout_ms': 5000}`.
* **SQL Server** – `dartcore_mssql` (**experimental**, on the pure-Dart `mssql_dart` driver). `registerMssql()`; `ssl: disable` sends the
  login unencrypted, `SslMode.require` encrypts without verifying the (usually self-signed) certificate, `verifyFull` verifies it
  (`options: {'ca_file': ...}`). `options: {'instance': 'SQLEXPRESS'}` for a named instance. Not yet verified against a live server;
  see [DATABASE_COMPATIBILITY.md](../DATABASE_COMPATIBILITY.md).
* **Supabase** – connect to the project's Postgres host with `DatabaseDriver.postgres` and `ssl: SslMode.require`. Supabase
  Auth/Storage/Realtime are separate services and **not implemented**. The service-role key must never be shipped to
  clients; row-level security is bypassed by direct connections with a privileged role.

## Raw SQL (advanced)

```dart
final rows = await DB.select('SELECT * FROM users WHERE age > ?', [18]);   // placeholders are translated per dialect
final n = await DB.statement('UPDATE users SET active = ? WHERE id = ?', [false, 5]);
```

Never build the SQL string from user input; pass values as bindings.

## Transactions

```dart
await DB.transaction((tx) async {
  await tx.table('accounts').where('id', 1).decrement('balance', 100);
  await tx.table('accounts').where('id', 2).increment('balance', 100);
  await tx.transaction((inner) async { ... });     // SAVEPOINT; inner failure rolls back only inner work
});
```

Commit on success; rollback + rethrow on any exception. Use `tx`, not `DB`, inside the callback or the work happens
outside the transaction. A transaction is one database: DartCore never claims atomicity across different servers.
