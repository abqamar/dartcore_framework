# dartcore_framework

A simple, modular backend SDK for Dart: HTTP API, SQL query builder, validation and config in one import. Add a database adapter and go.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. This is the umbrella package: it re-exports
`dartcore_core`, `dartcore_logging`, `dartcore_validation`, `dartcore_db` and `dartcore_api`.

## Install

```sh
dart pub add dartcore_framework
dart pub add dartcore_sqlite      # or dartcore_postgres / dartcore_mysql
```

Optional packages are added separately: `dartcore_migrations`, `dartcore_orm`, `dartcore_auth`, `dartcore_cache`,
`dartcore_storage`, `dartcore_dashboard`. Scaffold a whole project with the `dartcore_cli` tool.

## Usage

```dart
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

Future<void> main() async {
  registerSqlite();                  // registerPostgres() / registerMySql() for the other engines
  await DB.connect(driver: DatabaseDriver.sqlite, database: 'app.sqlite');
  await DB.statement('CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL)');

  final app = DartCore();            // reads APP_* configuration; disconnects the database on shutdown

  app.get('/notes', (request) async => Response.ok(await DB.table('notes').get()));
  app.post('/notes', (request) async {
    final v = Validate.request(await request.json(), {'text': 'required|string|max:500'});
    if (v.fails) return Response.validationError(v.errors);
    return Response.created(await DB.table('notes').insert(v.validated));
  });

  await app.start(port: 8080);       // Ctrl+C stops gracefully
}
```

`DartCore` extends `App` from `dartcore_api` and holds a `DatabaseManager`. The package also provides
`databaseExistenceChecker` so `unique:` and `exists:` validation rules can query your database.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_framework/example/dartcore_framework_example.dart) exercises such an app in process.

## Status and limits

Pre-1.0: the API may change. The SQLite driver is synchronous and cannot be compiled with `dart compile exe` (use `dart build`
or another database). MySQL DDL is not transactional. The rate limiter and in-memory auth stores are per process.
Not built yet: SQL Server and Supabase adapters, S3 storage, Redis cache, OpenAPI generation.
See the [getting started guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/getting-started.md) and the
[implementation status](https://github.com/abqamar/dartcore_framework/blob/main/docs/status.md).
