# dartcore_postgres

PostgreSQL adapter for DartCore with pooled connections, transactions, savepoints and typed error messages.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. It plugs into `dartcore_db`.

## Install

```sh
dart pub add dartcore_postgres
dart pub add dartcore_db      # the DB facade and query builder
```

Register the adapter once at startup, then connect with `DB.connect`.

## Usage

```dart
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';

Future<void> main() async {
  registerPostgres();

  await DB.connect(
    driver: DatabaseDriver.postgres,
    host: 'localhost',
    port: 5432,
    database: 'app',
    username: 'app',
    password: 'change-me',        // load from Config.require('DB_PASSWORD') in real code
    ssl: SslMode.disable,         // disable | require | verifyFull
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

The [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_postgres/example/dartcore_postgres_example.dart) needs a running PostgreSQL server; it was only analyzed here, not run.
Set `options: {'application_name': 'api'}` to name the session. TLS is used whenever `ssl` is not `disable`.

- Tested against PostgreSQL 16 in this repository's integration suite; other versions are untested.
- Supabase: connect to the project's Postgres host with `ssl: SslMode.require`. This is a plain Postgres connection (Supabase Auth, Storage and Realtime are not implemented).

## Status and limits

Pre-1.0: the API may change. See [database](https://github.com/abqamar/dartcore_framework/blob/main/docs/database.md) and [engine compatibility](https://github.com/abqamar/dartcore_framework/blob/main/DATABASE_COMPATIBILITY.md).
