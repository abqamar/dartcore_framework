# Getting started

## 1. Install

**With the CLI (recommended):**

```bash
dart pub global activate dartcore_cli                 # adds the `dartcore` command
dartcore create my_api --database postgres --auth     # writes a project and runs `dart pub get`
```

**In an existing Dart project:**

```bash
dart pub add dartcore_framework dartcore_postgres dartcore_migrations
```

Pick the adapter you need: `dartcore_postgres`, `dartcore_mysql`, `dartcore_sqlite` or `dartcore_mssql` (experimental). Requires Dart >= 3.10.

**Until the first pub.dev release,** install from a checkout. `dartcore create --path <checkout>` writes the path
dependencies and overrides for you:

```bash
git clone https://github.com/abqamar/dartcore_framework.git && cd dartcore_framework
dart pub get                                          # resolves the whole workspace
dart pub global activate --source path packages/dartcore_cli
dartcore create my_api --database postgres --auth --path "$(pwd)"
```

## 2. Hello API (no database)

```dart
import 'package:dartcore_framework/dartcore_framework.dart';

Future<void> main() async {
  final app = DartCore();
  app.get('/hello/:name', (request) =>
      Response.success({'greeting': 'Hello, ${request.param('name')}!'}));
  await app.start(port: 8080);            // Ctrl+C stops gracefully
}
```

## 3. Add a database

```dart
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

registerSqlite();
await DB.connect(driver: DatabaseDriver.sqlite, database: 'app.sqlite');
await DB.statement('CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL)');

app.get('/notes', (r) async => Response.ok(await DB.table('notes').get()));
app.post('/notes', (r) async {
  final v = Validate.request(await r.json(), {'text': 'required|string|max:500'});
  if (v.fails) return Response.validationError(v.errors);
  return Response.created(await DB.table('notes').insert(v.validated));
});
```

`v.validated` contains only fields that have rules, so extra input is never inserted.

## 4. Or generate a project

```bash
dartcore create my_api --database postgres --architecture mvc --auth
cd my_api
dartcore migrate && dartcore serve
```

See [cli.md](cli.md). Configuration is read from `.env` (`APP_PORT`, `APP_ENV`, `DB_*`, `JWT_SECRET`); the app picks
`APP_PORT` automatically when you call `DartCore()`.

## Configuration reference

| Key | Default | Meaning |
|---|---|---|
| `APP_NAME` | `DartCore` | name in logs |
| `APP_ENV` | `development` | `development`, `testing`, `staging`, `production` (unknown → production) |
| `APP_HOST` | `127.0.0.1` dev/test, `0.0.0.0` staging/prod | bind address |
| `APP_PORT` | `8080` | port |
| `APP_DEBUG` | true only in development | include error details in 500 responses |
| `APP_TRUST_PROXY` | `false` | honour `X-Forwarded-For` for `request.ip` |
| `DB_DRIVER` `DB_HOST` `DB_PORT` `DB_DATABASE` `DB_USERNAME` `DB_PASSWORD` `DB_SSL` `DB_POOL_MAX` `DB_CONNECT_TIMEOUT` `DB_QUERY_TIMEOUT` | – | `ConnectionConfig.fromConfig(Config.instance)` |
| `JWT_SECRET` | – (required for auth) | ≥ 32 bytes |

```dart
await Config.load();                     // .env, then .env.<APP_ENV>, process env wins
final port = Config.getInt('APP_PORT', 8080);
await Config.load(sources: [DirectorySecretSource('/run/secrets')]); // external secrets
```
