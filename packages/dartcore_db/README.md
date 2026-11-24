# dartcore_db

Database abstraction for DartCore: a safe query builder, SQL compilers for PostgreSQL, MySQL and SQLite, a connection pool and transactions.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. `dartcore_framework` re-exports this package.

## Install

```sh
dart pub add dartcore_db
```

This package contains no driver. Add an adapter (`dartcore_postgres`, `dartcore_mysql` or `dartcore_sqlite`) and register it once at startup.

## Usage

```dart
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';   // or dartcore_postgres / dartcore_mysql

Future<void> main() async {
  registerSqlite();                                      // registerPostgres() / registerMySql()
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');

  final adults = await DB.table('users')
      .select(['id', 'name'])
      .where('age', '>=', 18)
      .orderBy('name')
      .limit(20)
      .get();

  final user = await DB.table('users').insert({'name': 'Ada'});   // returns the stored row
  final page = await DB.table('users').orderBy('id').paginate(page: 1, limit: 20);

  await DB.transaction((tx) async {                      // commit on success, rollback on error
    await tx.table('accounts').where('id', 1).decrement('balance', 100);
    await tx.table('accounts').where('id', 2).increment('balance', 100);
  });
}
```

Connection settings can also come from configuration: `DB.connectWith(ConnectionConfig.fromConfig(Config.instance))` reads the `DB_*` keys.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_db/example/dartcore_db_example.dart) compiles one query for four dialects without needing a database.

## Safety

Values are bound parameters; identifiers are validated and quoted; operators are whitelisted. `update`, `increment` and `delete`
refuse to run without a `where` unless `allowAll: true`. Raw SQL APIs exist for advanced cases and take `?` placeholders.

## Status and limits

Pre-1.0: the API may change. There is no SQL Server adapter yet (the dialect compiles SQL but nothing executes it).
`ILIKE` works only on PostgreSQL and throws elsewhere. A SQL transaction covers one database only.
See [database](https://github.com/abqamar/dartcore_framework/blob/main/docs/database.md), the
[query builder guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/query-builder.md) and
[engine compatibility](https://github.com/abqamar/dartcore_framework/blob/main/DATABASE_COMPATIBILITY.md).
