# Tutorial: build and deploy a Tasks API

You will build a small but real backend: users who register and sign in with JWT tokens, and a **tasks** resource that
each user can only see and change for themselves. Then you will test it and put it on an Ubuntu server as a single binary.
No Docker is used anywhere.

**You will need:** Dart ≥ 3.10, PostgreSQL (any 12+; a local install is fine), and `curl`. For the last part, an Ubuntu
server you can SSH into. About an hour.

**What was verified.** The finished project is [`examples/tasks_api`](../examples/tasks_api), with its own test suite
(6 tests, run on in-memory SQLite). Every command and response shown in parts 5 and 6 was produced by running the project
on SQLite. The PostgreSQL-specific steps (creating the database, connecting) use the same code path but were not run
against a live server while writing this. The deployment part has the same caveats as [deployment.md](deployment.md#what-was-verified-and-what-was-not):
the install script has not yet been executed on a real Ubuntu host, so try it on a throwaway server first.

---

## 1. Install the CLI

```bash
dart pub global activate dartcore_cli
dartcore --version
```

> **Before the first pub.dev release,** install from source instead:
> ```bash
> git clone https://github.com/abqamar/dartcore_framework.git
> cd dartcore_framework && dart pub get
> dart pub global activate --source path packages/dartcore_cli
> ```
> and add `--path /path/to/dartcore_framework` to the `dartcore create` command below.

If `dartcore` is not found, add `~/.pub-cache/bin` to your `PATH`.

## 2. Create the project

```bash
dartcore create tasks_api --database postgres --architecture mvc --auth
cd tasks_api
```

`--architecture` decides where generated files go (`simple`, `mvc`, `clean` or `modular`); `--auth` adds register, login,
refresh, `me` and logout routes. The command writes the project and runs `dart pub get`. What you got:

```
bin/server.dart               the web server entry point
bin/console.dart              what `dartcore migrate`, `db:seed`, `doctor` run
lib/config/database.dart      registers the PostgreSQL adapter and connects from .env
lib/auth/auth.dart            auth service + /auth/* routes
lib/routes/api.dart           every route, in one place
lib/controllers/              request handlers
database/migrations/          schema changes, one class per file
database/seeders/             sample data
.env  .env.example            configuration (.env is git-ignored and already has a random JWT_SECRET)
dartcore.yaml                 tells the CLI which architecture and database this project uses
```

## 3. Prepare PostgreSQL and `.env`

Create a database and a user that owns it. Owning the database matters: the migration tables will belong to this user,
which is what the app connects as.

```bash
# Linux:  sudo -u postgres psql          macOS (Homebrew): psql postgres
CREATE USER tasks_app WITH PASSWORD 'choose-a-strong-password';
CREATE DATABASE tasks_api OWNER tasks_app;
```

Open `.env` and set the database section:

```ini
DB_DRIVER=postgres
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=tasks_api
DB_USERNAME=tasks_app
DB_PASSWORD=choose-a-strong-password
```

Use `127.0.0.1`, not `localhost`: `localhost` may resolve to IPv6 (`::1`) while PostgreSQL listens on IPv4 only, which gives
"could not connect". Never commit `.env`; `.env.example` is the shareable template.

## 4. Check, migrate, run

```bash
dartcore doctor
```

`doctor` checks the project, `.env` (it even notices if `.env` is a directory), the database keys, the length of
`JWT_SECRET`, the storage folder, a real `SELECT 1` against your database, how many migrations are pending, and whether the
port is free. Each line is `OK`, `WARN` or `FAIL`, with a fix for anything that is not OK. Sample output (SQLite, before
migrating; abridged):

```
OK    Project: dartcore.yaml found in /…/tasks_api.
OK    .env: regular file with 13 key(s).
OK    Database settings: all required DB_* keys are set.
OK    JWT_SECRET: set (64 bytes).
OK    Database connection: SELECT 1 succeeded (…).
WARN  Migrations: 0 applied, 2 pending.
      Fix: run "dartcore migrate" (or install.sh --migrate on the server).

7 ok, 2 warning(s), 0 failure(s).
```

A `FAIL` on the database connection prints the real reason and a hint (wrong password, database missing, nothing listening
on the port, and so on). Fix what it says, run it again, then:

```bash
dartcore migrate
dartcore serve                 # http://127.0.0.1:8080
```

In a second terminal:

```bash
curl -s localhost:8080/health
# {"success":true,"message":"Success","data":{"status":"ok"},"meta":null}
```

## 5. Try authentication

```bash
curl -s -X POST localhost:8080/auth/register -H 'Content-Type: application/json' \
  -d '{"name":"Ada","email":"ada@example.com","password":"correct-horse-battery"}'
```

```json
{"success":true,"message":"Registered","data":{"access_token":"eyJhbGciOiJIUzI1NiIs…","refresh_token":"rt_…","token_type":"Bearer","expires_in":900},"meta":null}
```

You get a short-lived **access token** (15 minutes) and a long-lived, **single-use refresh token**: each `/auth/refresh`
call hands out a new pair and kills the old refresh token. If an old refresh token is ever replayed, the whole chain is
revoked. Passwords are stored as Argon2id hashes. Save the token in your shell:

```bash
TOKEN=eyJhbGciOiJIUzI1NiIs…        # the access_token from the response
curl -s localhost:8080/auth/me -H "Authorization: Bearer $TOKEN"
```

## 6. Add the tasks feature

### 6.1 The migration

```bash
dartcore make:migration create_tasks_table
```

This creates `database/migrations/<timestamp>_create_tasks_table.dart` and registers it. Fill in the table:

```dart
@override
Future<void> up(SchemaBuilder schema) => Schema.create('tasks', (table) {
      table.id();
      table.foreignId('user_id').references('users').onDelete('cascade');
      table.string('title');
      table.text('description').nullable();
      table.string('status', 20).defaultValue('todo');
      table.timestamp('due_at').nullable();
      table.timestamps();
      table.index(['user_id', 'status']);
    });
```

```bash
dartcore migrate
# Migrating: 2026_11_24_131948_create_tasks_table
# Migrated:  2026_11_24_131948_create_tasks_table
```

`dartcore migrate:status` shows what ran, and `dartcore migrate:rollback` undoes the last batch.

### 6.2 The controller

Handlers are plain functions of `Request` returning a `Response`. The important design rule: **every query is scoped by the
signed-in user's id**, so a task that is not yours is indistinguishable from one that does not exist (404, never 403).

```bash
dartcore make:controller Task --resource --table=tasks     # a starting point; we replace it
```

The generator does not know your columns, so write the real one at `lib/controllers/task_controller.dart`:

```dart
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_framework/dartcore_framework.dart';

class TaskController {
  static const _statuses = 'todo,doing,done';
  static const _columns = ['id', 'title', 'description', 'status', 'due_at', 'created_at', 'updated_at'];
  static const _sortable = ['id', 'title', 'status', 'due_at', 'created_at'];

  Future<Object> _userId(Request request) async => (await Auth.user(request))!.id;

  Future<Response> index(Request request) async {
    final userId = await _userId(request);
    final page = int.tryParse(request.query('page') ?? '') ?? 1;
    final limit = (int.tryParse(request.query('limit') ?? '') ?? 20).clamp(1, 100);
    final status = request.query('status');
    final search = request.query('q');
    final result = await DB
        .table('tasks')
        .select(_columns)
        .where('user_id', userId)
        .when(status != null, (q) => q.where('status', status))
        .when(search != null && search.isNotEmpty, (q) => q.where('title', 'like', '%$search%'))
        .orderByAllowed(request.query('sort'), _sortable, fallback: 'id')
        .paginate(page: page < 1 ? 1 : page, limit: limit);
    return Response.success(result.data, meta: result.meta);
  }

  Future<Response> store(Request request) async {
    final v = Validate.request(await request.json(), {
      'title': 'required|string|min:2|max:200',
      'description': 'nullable|string|max:5000',
      'status': 'sometimes|in:$_statuses',
      'due_at': 'nullable|date',
    });
    if (v.fails) return Response.validationError(v.errors);
    final now = DateTime.now().toUtc();
    final created = await DB.table('tasks').insert({
      ...v.validated,                       // only fields that have rules: extra input never reaches the database
      'user_id': await _userId(request),    // from the token, never from the request body
      'created_at': now,
      'updated_at': now,
    });
    return Response.success(await DB.table('tasks').select(_columns).find(created['id']!),
        message: 'Task created', status: 201);
  }

  // show / update / destroy follow the same pattern; see examples/tasks_api for the complete file.
}
```

A few things worth noticing:

* `where('title', 'like', '%$search%')` is safe: values are always **bound parameters**, never pasted into the SQL.
* `orderByAllowed` takes the `?sort=` value from the client but only accepts columns from your whitelist.
* `update` and `delete` **refuse to run without a `where`**, so a forgotten condition cannot wipe a table.
* `v.validated` contains only fields that had a rule. Unknown JSON keys are dropped, not inserted.

The complete controller, with `show`, `update` and `destroy`, is in
[`examples/tasks_api/lib/controllers/task_controller.dart`](../examples/tasks_api/lib/controllers/task_controller.dart).

### 6.3 The routes

Edit `lib/routes/api.dart`. The generated project also registers `GET /api/users`, which lists **every** user to any signed-in
user. That is a fine demo and a poor default, so remove it and add the task routes inside the protected group:

```dart
app.group('/api', middleware: [Auth.middleware()], routes: () {
  final tasks = TaskController();
  app.get('/tasks', tasks.index, name: 'tasks.index');
  app.post('/tasks', tasks.store, name: 'tasks.store');
  app.get('/tasks/:id', tasks.show, name: 'tasks.show');
  app.put('/tasks/:id', tasks.update, name: 'tasks.update');
  app.delete('/tasks/:id', tasks.destroy, name: 'tasks.destroy');
});
```

Delete `lib/controllers/user_controller.dart` and its import, then check the routes:

```bash
dartcore route:list
# GET     /health  (health)
# GET     /api/tasks  (tasks.index)
# POST    /api/tasks  (tasks.store)
# GET     /api/tasks/:id  (tasks.show)
# PUT     /api/tasks/:id  (tasks.update)
# DELETE  /api/tasks/:id  (tasks.destroy)
# POST    /auth/register  … /auth/login  /auth/refresh  /auth/me  /auth/logout
```

### 6.4 Use it

Restart `dartcore serve`, then:

```bash
curl -s -X POST localhost:8080/api/tasks -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"title":"Write the tutorial","status":"doing"}'
```
```json
{"success":true,"message":"Task created","data":{"id":1,"title":"Write the tutorial","description":null,"status":"doing","due_at":null,"created_at":"2026-11-24T13:20:45.930126Z","updated_at":"2026-11-24T13:20:45.930126Z"},"meta":null}
```

Bad input is rejected with field-level errors (HTTP 422):

```bash
curl -s -X POST localhost:8080/api/tasks -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"title":"x","status":"later"}'
```
```json
{"success":false,"message":"Validation failed","errors":{"title":["The title must be at least 2 characters."],"status":["The selected status is invalid."]}}
```

Filter, search and paginate:

```bash
curl -s "localhost:8080/api/tasks?status=doing&q=tutorial&limit=10" -H "Authorization: Bearer $TOKEN"
```
```json
{"success":true,"message":"Success","data":[{"id":1,"title":"Write the tutorial", … }],"meta":{"current_page":1,"per_page":20,"total":1,"last_page":1,"has_next_page":false,"has_previous_page":false}}
```

And the rules that matter most:

```bash
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/api/tasks                      # 401  no token
# register a second user "bob", then, with Bob's token:
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/api/tasks/1 -H "Authorization: Bearer $BOB"   # 404  Ada's task
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE localhost:8080/api/tasks/1 -H "Authorization: Bearer $BOB"   # 404
```

## 7. Write tests

Tests run the whole app **in memory**, with no server and no port: `app.send(method, path, headers:, body:)` goes through
the same router and middleware as a real request. Use an in-memory SQLite database so tests need no PostgreSQL:

```dart
setUp(() async {
  registerSqlite();
  Config.reset();
  Config.set('JWT_SECRET', 'a-test-secret-that-is-at-least-32-bytes-long!');
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
  await Migrator(DB.connection(), migrations).migrate();
  await configureAuth();
  app = DartCore(database: DB.manager, logger: Logger(level: LogLevel.fatal, handlers: []));
  registerRoutes(app);
});
tearDown(DB.reset);

test('a user cannot read another user\'s task', () async {
  final ada = await register('ada@example.com');
  final bob = await register('bob@example.com');
  final created = await app.send('POST', '/api/tasks', headers: bearer(ada), body: {'title': 'Ada only'});
  final id = ((await body(created))['data'] as Map)['id'];
  final r = await app.send('GET', '/api/tasks/$id', headers: bearer(bob));
  expect(r.statusCode, 404);
});
```

Create `test/tasks_test.dart` with the imports of `dartcore_framework`, `dartcore_migrations`, `dartcore_sqlite`, `package:test`,
your `lib/auth/auth.dart` and `lib/routes/api.dart`, and `../database/migrations/index.dart`, add the `register`, `bearer` and `body`
helpers, then run `dart test`. The full file is [`examples/tasks_api/test/tasks_test.dart`](../examples/tasks_api/test/tasks_test.dart).

> SQLite and PostgreSQL differ in small ways (for example SQLite returns `1` for booleans). The query builder hides most of
> them, but keep a few tests against a real PostgreSQL for anything engine-specific.

## 8. Production habits (optional, a few lines each)

```dart
// bin/server.dart
app.use(const SecurityHeadersMiddleware());                                 // already generated
app.use(CorsMiddleware(allowedOrigins: ['https://app.example.com']));        // only if a browser app calls you
```

* **Rate limits:** the generated server limits every client to 300 requests/minute and `/auth/login` to 10/minute. The
  limiter is per process.
* **Monitoring dashboard:** add `dartcore_dashboard` and `Dashboard.attach(app, token: Config.require('DASHBOARD_TOKEN'))`
  to see endpoints, latency percentiles, errors and logs at `/_dashboard`. In production it requires a token. See [dashboard.md](dashboard.md).
* **Logs:** `Log.use(Logger(handlers: [ConsoleHandler(json: true)]))` writes JSON lines that `journalctl` and log shippers understand.
  Secrets (passwords, tokens, `Authorization`) are redacted.

## 9. Deploy to Ubuntu

The server needs only **PostgreSQL reachable** and, optionally, nginx. It does **not** need Dart, git, pub or Docker.

On the server, once: create the production database and user (as in part 3), and install nginx if you want HTTPS later
(`sudo apt install nginx certbot python3-certbot-nginx`).

On your machine, inside the project:

```bash
dartcore doctor                                    # fix every FAIL first
dartcore deploy:init --domain api.example.com      # writes deploy/: systemd unit, nginx site, install.sh (commit it)
dartcore build                                     # -> build/release/  (server, console, .env.example, deploy/)
```

`dartcore build` cross-compiles for Linux x64 from macOS, Linux or Windows in a few seconds (use `--target linux-arm64`
for ARM servers; `uname -m` prints `aarch64` there). Upload and install:

```bash
rsync -av build/release/ you@server:~/tasks_api-release/
ssh -t you@server 'cd ~/tasks_api-release && sudo ./deploy/install.sh --migrate --nginx'
```

The **first** run creates `/opt/tasks_api/.env` with `APP_ENV=production`, `APP_DEBUG=false` and freshly generated secrets,
then **stops** and lists what you must fill in (`DB_*`). Edit it and run the same command again:

```bash
ssh -t you@server 'sudo nano /opt/tasks_api/.env'          # DB_HOST=127.0.0.1, DB_DATABASE, DB_USERNAME, DB_PASSWORD
ssh -t you@server 'cd ~/tasks_api-release && sudo ./deploy/install.sh --migrate --nginx'
```

The script prints `[n/9]` progress: it creates a service user with no login, installs the binaries, runs the migrations
(only because you passed `--migrate`), installs and starts the systemd unit, sets up nginx, and finally calls `/health`.
It never overwrites an existing `.env`, and it is safe to re-run.

HTTPS, once DNS points at the server:

```bash
sudo certbot --nginx -d api.example.com
curl -s https://api.example.com/health
```

**Update later:** `dartcore build`, `rsync` again, run the same `install.sh` line. Your `.env` and `storage/` are kept, and the
previous binaries are saved as `server.prev` and `console.prev` for rollback. Logs: `journalctl -u tasks_api -f`.

Details, rollback and what the script does step by step: [deployment.md](deployment.md).

## 10. When something goes wrong

| You see | Likely cause | Do this |
|---|---|---|
| `dartcore: command not found` | pub's bin folder is not on `PATH` | add `~/.pub-cache/bin` to `PATH` |
| `FAIL Database connection … connection refused` | PostgreSQL is not running or listens elsewhere | start it; check `DB_PORT`; try `DB_HOST=127.0.0.1` |
| `FAIL … password authentication failed` | wrong `DB_USERNAME`/`DB_PASSWORD` | fix `.env`; test with `psql -h 127.0.0.1 -U <user> <db>` |
| `FAIL … database "…" does not exist` | not created yet | `CREATE DATABASE … OWNER …;` |
| `permission denied for table …` (42501) | the app user does not own or cannot access the tables | create the database `OWNER` the app user, or `ALTER TABLE … OWNER TO …` |
| `relation "…" already exists` (42P07) during `migrate` | tables exist but the migrations table is unreadable or empty | check ownership of `dartcore_migrations`; do not re-run blindly |
| `.env` problems on the server | `.env` created as a directory, or unreadable by the service user | `install.sh` refuses a directory; `ls -l /opt/<name>/.env` should be `-rw-------` owned by the service user |
| 401 on every request | token expired (15 min) or missing `Bearer ` prefix | call `/auth/refresh`, or log in again |
| 422 | validation | read the `errors` object: it is keyed by field |

Errors now carry the real reason: a failing query or connection prints a `Details:` line (what the database said) and a
`Hint:` line (what to try) in the console and logs. They are never sent to API clients in production. See
[troubleshooting.md](troubleshooting.md).

## Where next

* Relationships and models: [orm.md](orm.md) · schema builder and seeders: [migrations.md](migrations.md)
* Roles and permissions, API tokens, password reset: [auth.md](auth.md)
* Uploads: `dartcore_storage` ([README](../packages/dartcore_storage/README.md))
* Caching expensive queries: [cache-logging.md](cache-logging.md)
* How it fits together: [ARCHITECTURE.md](../ARCHITECTURE.md) · limits and security: [SECURITY.md](../SECURITY.md)
