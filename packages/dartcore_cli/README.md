# dartcore_cli

The `dartcore` command-line tool: scaffold projects, generate code, run migrations, diagnose your setup and build deployable binaries.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub global activate dartcore_cli
dartcore --version
```

## Usage

```sh
dartcore create my_api --database postgres --architecture mvc --auth
cd my_api
dartcore migrate
dartcore serve
```

| Area | Commands |
|---|---|
| Project | `create` (`--database postgres, mysql, sqlite, supabase`, `--architecture simple, mvc, clean, modular`, `--auth`) |
| Run | `serve`, `route:list` |
| Database | `migrate`, `migrate:rollback`, `migrate:reset`, `migrate:fresh`, `migrate:status`, `db:seed` |
| Generate | `make:controller`, `make:model`, `make:service`, `make:middleware`, `make:resource`, `make:validator`, `make:migration`, `make:seeder` |
| New in 0.1.0 | `build`, `deploy:init`, `doctor` |

`build` produces a deployable binary, `deploy:init` writes deployment files for your project, and `doctor` diagnoses
common setup problems. Run `dartcore --help` (or `dartcore <command> --help`) for the options of each command, and see the
[CLI guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/cli.md) and [deployment guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/deployment.md).

Generators validate names (no path traversal) and never overwrite existing files. Destructive migration commands ask for
confirmation and refuse to run in production without `--force`.

## Status and limits

Pre-1.0: commands and flags may change. Generated projects use the other DartCore packages, which are pre-1.0 as well.
`docs:generate` (OpenAPI) is reserved and currently exits with an explanatory error; `mssql` is refused because there is no
SQL Server adapter. SQLite projects cannot use `dart compile exe`. `make:controller --resource` does not know your columns, so
edit its validation rules. See the [implementation status](https://github.com/abqamar/dartcore_framework/blob/main/docs/status.md) and
[troubleshooting](https://github.com/abqamar/dartcore_framework/blob/main/docs/troubleshooting.md).
