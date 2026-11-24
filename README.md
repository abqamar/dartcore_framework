# DartCore Framework

[![CI](https://github.com/abqamar/dartcore_framework/actions/workflows/ci.yml/badge.svg)](https://github.com/abqamar/dartcore_framework/actions/workflows/ci.yml)

**A simple, batteries-included backend framework for pure Dart.** REST routing, a safe SQL query builder,
migrations, an explicit ORM, JWT authentication, validation, caching, logging, file storage, a monitoring dashboard and
a CLI that scaffolds your project and ships it to a plain Ubuntu server as **one binary: no Docker, no Dart SDK on the server.**

```dart
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';

Future<void> main() async {
  await Config.load();                         // .env + environment variables
  registerPostgres();                          // install only the database adapter you use
  await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));

  final app = DartCore();

  app.get('/users', (request) async => Response.ok(await DB.table('users').get()));

  app.post('/users', (request) async {
    final v = Validate.request(await request.json(), {
      'name': 'required|string|min:2',
      'email': 'required|email',
    });
    if (v.fails) return Response.validationError(v.errors);
    return Response.created(await DB.table('users').insert(v.validated));
  });

  await app.start();                           // port from APP_PORT, graceful shutdown on Ctrl+C / SIGTERM
}
```

> **Status: 0.1.0, pre-release.** The core, database layer (PostgreSQL, MySQL, SQLite), migrations, ORM, auth,
> validation, cache, storage, dashboard and CLI are implemented and tested. Not implemented yet: OpenAPI/Swagger,
> Redis cache, S3 storage, SQL Server adapter, Supabase services. Read [docs/status.md](docs/status.md) for the exact,
> verified state, including what has and has not been run against a real server.

## Why DartCore

| You want | DartCore gives you |
|---|---|
| to start fast | `dartcore create my_api` writes a running project (routes, users migration, `.env`, tests-ready layout) |
| SQL without injection bugs | a query builder that binds every value, validates identifiers, and refuses `UPDATE`/`DELETE` without `WHERE` |
| auth you do not have to design | Argon2id passwords, JWT access tokens, **rotating** refresh tokens with replay detection, API tokens, RBAC |
| schema changes you can trust | migrations with a schema builder, rollback, status, seeders |
| to know what happens in production | structured logs with secret redaction, request ids, a built-in monitoring dashboard |
| easy deployment | `dartcore build` makes a Linux binary on your machine; `dartcore deploy:init` writes the systemd + nginx + install script |
| to keep the code yours | explicit models and plain Dart; no reflection, no code generation required |

## Install

```bash
dart pub global activate dartcore_cli          # the `dartcore` command
dartcore create my_api --database postgres --auth
cd my_api
```

In an existing project:

```bash
dart pub add dartcore_framework dartcore_postgres dartcore_migrations
```

> **Not on pub.dev yet?** Until the first release, install from source. Requires Dart ≥ 3.10.
> ```bash
> git clone https://github.com/abqamar/dartcore_framework.git
> cd dartcore_framework && dart pub get
> dart pub global activate --source path packages/dartcore_cli
> dartcore create my_api --database postgres --auth --path "$(pwd)"
> ```

## Five-minute tour

```bash
dartcore create my_api --database postgres --auth --path /path/to/dartcore_framework   # drop --path once published
cd my_api

# 1. Put your PostgreSQL details in .env (DB_HOST, DB_DATABASE, DB_USERNAME, DB_PASSWORD)
# 2. Check that everything is wired up
dartcore doctor

# 3. Create the tables and run
dartcore migrate
dartcore serve                                  # http://127.0.0.1:8080
curl -s localhost:8080/health
```

The **[complete tutorial](docs/tutorial.md)** builds a real API from zero to a server in production, step by step.

## What is in the box

| Package | Purpose |
|---|---|
| [`dartcore_framework`](packages/dartcore_framework) | The umbrella: the `DartCore` app plus everything below in one import |
| [`dartcore_core`](packages/dartcore_core) | Exceptions, layered configuration (`.env`, environment, secret sources) |
| [`dartcore_logging`](packages/dartcore_logging) | Structured logging, redaction, request-id correlation |
| [`dartcore_api`](packages/dartcore_api) | Router, request/response, middleware (CORS, rate limit, security headers), graceful shutdown |
| [`dartcore_validation`](packages/dartcore_validation) | Rule-based validation: nested, wildcard, conditional, async `unique`/`exists` |
| [`dartcore_db`](packages/dartcore_db) | Query builder, SQL dialects, pool, transactions with savepoints |
| [`dartcore_postgres`](packages/dartcore_postgres) · [`mysql`](packages/dartcore_mysql) · [`sqlite`](packages/dartcore_sqlite) | Database adapters: install only the one you use |
| [`dartcore_migrations`](packages/dartcore_migrations) | Schema builder, migrations, seeders, console commands |
| [`dartcore_orm`](packages/dartcore_orm) | Explicit models, relationships, eager loading, soft deletes |
| [`dartcore_auth`](packages/dartcore_auth) | Argon2id, JWT, refresh-token rotation, API tokens, sessions, RBAC |
| [`dartcore_cache`](packages/dartcore_cache) | In-memory cache with TTL/LRU, cache-aside |
| [`dartcore_storage`](packages/dartcore_storage) | Local file storage with content-sniffing upload validation |
| [`dartcore_dashboard`](packages/dartcore_dashboard) | Runtime monitoring dashboard served from inside your app |
| [`dartcore_cli`](packages/dartcore_cli) | The `dartcore` command: scaffolding, generators, migrations, `doctor`, `build`, `deploy:init` |

## Deploy to Ubuntu (no Docker)

```bash
dartcore build                                  # Linux binary + console + deploy files in build/release/
rsync -av build/release/ you@server:~/my_api-release/
ssh -t you@server 'cd ~/my_api-release && sudo ./deploy/install.sh --migrate --nginx'
```

The server needs PostgreSQL reachable and (optionally) nginx. It does not need Dart, git or pub.
The full flow, HTTPS, updates and rollback are in **[docs/deployment.md](docs/deployment.md)**.

## Documentation

**Start here:** [Tutorial](docs/tutorial.md) · [Getting started](docs/getting-started.md) · [Deployment](docs/deployment.md) · [Troubleshooting](docs/troubleshooting.md)

**Guides:** [HTTP](docs/http.md) · [Middleware](docs/middleware.md) · [Database](docs/database.md) · [Query builder](docs/query-builder.md) ·
[Migrations](docs/migrations.md) · [ORM](docs/orm.md) · [Auth](docs/auth.md) · [Validation](docs/validation.md) ·
[Cache & logging](docs/cache-logging.md) · [Dashboard](docs/dashboard.md) · [CLI](docs/cli.md) · [Testing](docs/testing.md) ·
[Custom adapters](docs/custom-adapters.md)

**Design:** [Architecture](ARCHITECTURE.md) · [API design](API_DESIGN.md) · [Security](SECURITY.md) ·
[Database compatibility](DATABASE_COMPATIBILITY.md) · [Package structure](PACKAGE_STRUCTURE.md) · [Roadmap](ROADMAP.md) · [Status](docs/status.md)

## Examples

* [`examples/basic_api`](examples/basic_api): a small API with no database, and a dashboard demo.
* [`examples/complete_application`](examples/complete_application): users, products, JWT auth, CRUD, validation and pagination on PostgreSQL (or SQLite).
* [`examples/tasks_api`](examples/tasks_api): the API built step by step in the [tutorial](docs/tutorial.md).

## Develop and test

```bash
dart pub get                 # resolves the whole workspace (Dart >= 3.10)
./scripts/test_all.sh        # format check, analyzer, every package's tests, examples
```

The PostgreSQL/MySQL contract tests (`integration_tests`) need running servers; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing and license

Contributions are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first, and [SECURITY.md](SECURITY.md) to report a vulnerability.
**License:** [MIT](LICENSE).
