# CLI (`dartcore_cli`)

```bash
dart pub global activate --source path packages/dartcore_cli     # until it is published: dart pub global activate dartcore_cli
dartcore --version
```

Verified: path activation works. (A path-activated executable prints pub's "Resolving dependencies…" lines to stderr on every
run; that noise goes away once the package is published and activated from pub.dev.)

## Create a project

```bash
dartcore create my_api                                    # prompts when run in a terminal
dartcore create my_api -d postgres -a clean --auth
```

* `--database` (`-d`): `postgres` | `mysql` | `sqlite` | `supabase` (direct PostgreSQL connection only; Supabase services are
  not implemented). `mssql` is refused (no adapter).
* `--architecture` (`-a`): `simple` | `mvc` (default) | `clean` | `modular`. Controls where `make:*` puts files
  (`lib/controllers`, `lib/presentation/controllers` + `lib/domain` + `lib/data`, or `lib/modules/<m>/…`) and is recorded in
  `dartcore.yaml`.
* `--auth`: JWT register/login/refresh/me/logout routes, persistent token stores, protected users list.
* `--path <dartcore checkout>`: use local packages (needed until publication). `--no-pub-get` skips `dart pub get`.

Generated: `bin/server.dart`, `bin/console.dart`, `lib/config/database.dart`, `lib/routes/api.dart`, a users controller and
migration, seeder registry, `.env` (random `JWT_SECRET`, git-ignored), `.env.example`, `.gitignore`, `README.md`.
The result analyzes cleanly and runs (verified; see [status.md](status.md)).

## Run

`dartcore serve [--port 3000] [--host 0.0.0.0]` · `dartcore route:list` · `dartcore migrate` · `migrate:rollback [--step N]` ·
`migrate:reset` · `migrate:fresh [--seed]` · `migrate:status` / `db:status` · `db:seed [--class=Name]` · `doctor`.
These run `dart run bin/server.dart` / `bin/console.dart` inside the project (found by walking up to `dartcore.yaml`).

## Generate

| Command | Output |
|---|---|
| `make:controller Name [--resource --table=t]` | controller; `--resource` = CRUD with validation + pagination + explicit columns |
| `make:model Name [-m] [--fields=a:string,b:int,c:bool,d:double,e:datetime] [--soft-deletes]` | ORM model (+ migration) |
| `make:service Name` · `make:middleware Name` · `make:resource Name` · `make:validator Name` | skeletons |
| `make:migration create_x_table` / `add_y_to_x_table` | migration (create vs alter template), auto-registered |
| `make:seeder Name [--table=t]` | seeder, auto-registered |

Generators validate names (no path traversal), never overwrite existing files, and register migrations/seeders in the
`index.dart` files. `docs:generate` is reserved for OpenAPI and currently exits with an explanatory error.

## Deploy without Docker

Three commands take a project from your laptop to an Ubuntu server that has no Dart SDK, git or pub
(full walkthrough: [deployment.md](deployment.md)).

### `dartcore build [--target linux-x64|linux-arm64|host] [--output build/release] [--no-console]`

Runs `dart pub get`, then `dart compile exe` for `bin/server.dart` and `bin/console.dart` into the output folder, and
bundles `.env.example` and `deploy/` (generated with defaults if missing). The default target is `linux-x64`; it is passed to
`dart compile exe` as `--target-os linux --target-arch x64|arm64`, so you can build for Linux from macOS or Windows
(verified on Dart 3.13 / macOS arm64: both targets produce ELF binaries, about 10 MB `server` and 8 MB `console`, ~8 s for
a Postgres project). `--target host` compiles for the current machine only and warns if that is not Linux. If your SDK has no
`--target-os`, the command stops and tells you to build on the target OS with `--target host`.

```
build/release/
  server            self-contained binary (the API)
  console           self-contained binary (console migrate, migrate:status, doctor ...)
  .env.example
  deploy/           <name>.service  nginx.conf  install.sh  README.md
```

`.env` is never bundled. **SQLite projects are refused** with a clear message: the `sqlite3` package needs a native build hook
that `dart compile exe` does not support. Use PostgreSQL or MySQL for deployments.

### `dartcore deploy:init [--name my_api] [--domain api.example.com] [--user my_api] [--port 8080] [--force]`

Writes `./deploy/`: a hardened systemd unit (dedicated user, `NoNewPrivileges`, `ProtectSystem=full`, writable only
`/opt/<name>/storage`), an nginx reverse-proxy site, `install.sh` and a `README.md`. Defaults: name from `pubspec.yaml`,
user = name, port from `.env.example`. Names, user, domain and port are validated because they end up in shell and config
files. Existing files are kept unless `--force`.

`install.sh` runs on the server as root from the unpacked bundle: `sudo ./deploy/install.sh [--migrate] [--nginx] [--no-start]`.
It creates the service user, installs to `/opt/<name>`, never overwrites an existing `.env`, generates `JWT_SECRET` (and other
empty `*_SECRET`/`*_KEY` values) for a new `.env` and then **stops** so you can fill in `DB_PASSWORD`, migrates only with
`--migrate`, installs and starts the service, optionally installs the nginx site, and checks `GET /health`.

### `dartcore doctor`

Checks the project and prints `OK` / `WARN` / `FAIL` with a fix for each; exit code 1 if any `FAIL`. Secret values are never printed
(only key names and lengths).

| Check | Notes |
|---|---|
| `dartcore.yaml` | found by walking up from the current directory |
| `.env` | exists **and is a file** (a directory named `.env` is detected: DartCore would silently load nothing) |
| required keys | `DB_*` not empty / `CHANGE_ME`; `JWT_SECRET` at least 32 bytes (failure when the project uses auth or `APP_ENV=production`, else warning) |
| production sanity | warns for `CORS=*`-style values, `APP_DEBUG=true`, missing `APP_TRUST_PROXY` |
| database | runs `bin/console.dart doctor` inside the project with its own adapter: `SELECT 1`, then migrations applied/pending (without creating the migrations table) |
| storage | `STORAGE_PATH` (or `./storage` if present) exists and is writable |
| port | `APP_PORT` can be bound (a taken port is a warning: your server may be running) |

Projects generated before `doctor` existed need the `doctor` block in `bin/console.dart` (copy it from a freshly generated
project); otherwise the database check reports that the console could not run it.
