# dartcore_mssql

Microsoft SQL Server adapter for DartCore, built on a pure-Dart driver. **Experimental.**

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. It plugs into `dartcore_db`.

> **Status: experimental.** The conversions, error mapping and connection settings are unit-tested, and connecting to a
> closed port was run for real. The adapter has **not** been run against a live SQL Server by the DartCore project, so
> expect rough edges. The shared contract suite in `integration_tests` can be run against your server (see below);
> please report what you find.

## Install

```sh
dart pub add dartcore_mssql
dart pub add dartcore_framework      # or dartcore_db alone: the DB facade and query builder
```

It uses [`mssql_dart`](https://pub.dev/packages/mssql_dart), a pure-Dart TDS 7.4 driver: nothing to install on the
server, and `dartcore build` still produces a single native binary. (`mssql_dart` is a new package with its own TLS
implementation, `tlslite`: review it before trusting it with sensitive data.)

## Usage

```dart
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mssql/dartcore_mssql.dart';

Future<void> main() async {
  registerMssql();

  await DB.connect(
    driver: DatabaseDriver.mssql,
    host: 'localhost',
    port: 1433,
    database: 'app',
    username: 'app',
    password: 'change-me',        // load from Config.require('DB_PASSWORD') in real code
    ssl: SslMode.require,
    maxPoolSize: 10,
  );

  final rows = await DB.table('users').where('active', true).orderBy('id').paginate(page: 1, limit: 20);

  await DB.transaction((tx) async {
    await tx.table('accounts').where('id', 1).decrement('balance', 100);
  });

  await DB.disconnect();
}
```

Or from configuration: `DB.connectWith(ConnectionConfig.fromConfig(Config.instance))` with `DB_DRIVER=mssql`, `DB_HOST`,
`DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DB_SSL`. Generate a project with
`dartcore create my_api --database mssql`.

## TLS

| `ssl` | What happens |
|---|---|
| `SslMode.disable` | **Nothing is encrypted, including the login and password.** Only for a local development server. |
| `SslMode.require` | Encrypted, but the server certificate is not verified. The usual choice for SQL Server's default self-signed certificate. |
| `SslMode.verifyFull` | Encrypted, and the certificate chain and host name are verified. Use the `ca_file` option for your own CA. |

## Options (`ConnectionConfig.options`)

`instance` (a named instance: the port is then looked up through the SQL Server Browser, so `DB_PORT` is ignored),
`application_name`, `ca_file`, `trust_server_certificate`, `read_only_intent`.

## How it behaves

- **Parameters** are bound by the driver (`sp_executesql`), never spliced into the SQL.
- **`insert()`** returns the stored row through `OUTPUT INSERTED.*`. That clause is not allowed on a table that has
  enabled triggers (SQL Server error 334): insert without it and read the row back.
- **Strings** are sent as `nvarchar`. Comparing one with a `varchar` column makes SQL Server convert the column, which can
  skip an index.
- **Dates** are sent and returned as UTC (`datetime2`); `datetimeoffset` returns its UTC instant.
- **Decimals** come back as `int`/`double` when they fit exactly and as text otherwise, so nothing is silently rounded.
- **Errors** carry the real reason and a hint: a failed query becomes a `QueryException` with `details` such as
  `[2627] Violation of UNIQUE KEY constraint...` and a `hint`; a failed connection (login, wrong database, refused port,
  TLS) becomes a `ConnectionException` that says what to check. The password is never included.
- **Migrations:** the schema builder compiles SQL Server DDL; it is unit-tested but not yet run against a live server.

## Run the contract suite against your server

The same tests that verify PostgreSQL and MySQL can verify this adapter. In a clone of the repository, create an empty
database whose name contains `test` (the suites **drop every table** in it, and refuse any other name):

```sh
MSSQL_HOST=127.0.0.1 MSSQL_PORT=1433 MSSQL_DATABASE=dartcore_test \
MSSQL_USERNAME=sa MSSQL_PASSWORD='...' MSSQL_SSL=require \
  dart test integration_tests/test/mssql_test.dart integration_tests/test/mssql_migrations_test.dart
```

## Status and limits

Pre-1.0: the API may change. See [database](https://github.com/abqamar/dartcore_framework/blob/main/docs/database.md) and
[engine compatibility](https://github.com/abqamar/dartcore_framework/blob/main/DATABASE_COMPATIBILITY.md).
Windows (integrated) authentication, `Encrypt=Strict` and multiple active result sets are not supported by the driver.
