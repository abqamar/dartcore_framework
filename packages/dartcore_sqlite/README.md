# dartcore_sqlite

SQLite adapter for DartCore: a file or in-memory database for development, tests and small deployments.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. It plugs into `dartcore_db`.

## Install

```sh
dart pub add dartcore_sqlite
dart pub add dartcore_db      # the DB facade and query builder
```

Register the adapter once at startup, then connect with `DB.connect`.

## Usage

```dart
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

Future<void> main() async {
  registerSqlite();

  await DB.connect(driver: DatabaseDriver.sqlite, database: 'app.sqlite');   // a path, or ':memory:'

  final rows = await DB.table('users').where('active', true).get();

  await DB.transaction((tx) async {
    await tx.table('accounts').where('id', 1).decrement('balance', 100);
  });

  await DB.disconnect();
}
```

Or build the connection from `DB_*` configuration keys:
`DB.connectWith(ConnectionConfig.fromConfig(Config.instance))` (`DB_DRIVER`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DB_SSL`, `DB_POOL_MAX`).

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_sqlite/example/dartcore_sqlite_example.dart) uses an in-memory database.
Options: `options: {'wal': false, 'busy_timeout_ms': 5000}`.

- The SQLite driver is synchronous, so a query blocks the isolate while it runs.
- `dart compile exe` is rejected for programs that use `sqlite3` (build hooks); use `dart build` or a different database for AOT binaries.
- Migrations on SQLite cannot use `.change()` or add a UNIQUE or foreign-key column to an existing table (they throw `UnsupportedError`).

## Status and limits

Pre-1.0: the API may change. See [database](https://github.com/abqamar/dartcore_framework/blob/main/docs/database.md) and [engine compatibility](https://github.com/abqamar/dartcore_framework/blob/main/DATABASE_COMPATIBILITY.md).
