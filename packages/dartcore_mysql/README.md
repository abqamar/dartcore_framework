# dartcore_mysql

MySQL adapter for DartCore with pooled connections, transactions and consistent UTC date handling.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. It plugs into `dartcore_db`.

## Install

```sh
dart pub add dartcore_mysql
dart pub add dartcore_db      # the DB facade and query builder
```

Register the adapter once at startup, then connect with `DB.connect`.

## Usage

```dart
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mysql/dartcore_mysql.dart';

Future<void> main() async {
  registerMySql();

  await DB.connect(
    driver: DatabaseDriver.mysql,
    host: 'localhost',
    port: 3306,
    database: 'app',
    username: 'app',
    password: 'change-me',        // load from Config.require('DB_PASSWORD') in real code
    maxPoolSize: 10,
  );

  final rows = await DB.table('users').where('active', true).get();

  await DB.transaction((tx) async {
    await tx.table('accounts').where('id', 1).decrement('balance', 100);
  });

  await DB.disconnect();
}
```

Or build the connection from `DB_*` configuration keys:
`DB.connectWith(ConnectionConfig.fromConfig(Config.instance))` (`DB_DRIVER`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DB_SSL`, `DB_POOL_MAX`).

The [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_mysql/example/dartcore_mysql_example.dart) needs a running MySQL server; it was only analyzed here, not run.
Sessions are set to strict mode and UTC. Servers that need RSA key retrieval without TLS require
`options: {'allow_public_key_retrieval': true}`: understand the risk before enabling it.

- **MySQL DDL is not transactional**: a failing migration may be partly applied.
- Tested against MySQL 8.4; MariaDB is untested.
- `insert` re-reads the row by insert id (MySQL has no `RETURNING`), or returns your input.

## Status and limits

Pre-1.0: the API may change. See [database](https://github.com/abqamar/dartcore_framework/blob/main/docs/database.md) and [engine compatibility](https://github.com/abqamar/dartcore_framework/blob/main/DATABASE_COMPATIBILITY.md).
