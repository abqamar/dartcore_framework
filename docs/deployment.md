# Deployment

## Deploy to Ubuntu without Docker

The server needs only Ubuntu/Debian with systemd and a reachable PostgreSQL (or MySQL). It does **not** need the Dart SDK,
git, pub or Docker; optional: nginx and certbot. You build on your machine and upload one folder.

```bash
# 0. on your machine, inside the project
dartcore doctor                      # validates .env, database, migrations, storage, port
dartcore deploy:init --domain api.example.com     # writes deploy/ (once; commit it)
dartcore build                       # -> build/release/ (server, console, .env.example, deploy/)

# 1. upload
rsync -av build/release/ user@host:~/my_api-release/

# 2. install (first run creates /opt/my_api/.env with random secrets, then stops)
ssh -t user@host 'cd ~/my_api-release && sudo ./deploy/install.sh --migrate --nginx'
ssh -t user@host 'sudo nano /opt/my_api/.env'                          # fill in DB_PASSWORD etc.
ssh -t user@host 'cd ~/my_api-release && sudo ./deploy/install.sh --migrate --nginx'   # same command again
```

* **Update:** `dartcore build`, `rsync`, run the same install command. `.env` and `storage/` are kept; the previous binaries are
  saved as `server.prev` / `console.prev`.
* **Roll back:** `cd /opt/my_api && sudo mv server.prev server && sudo mv console.prev console && sudo systemctl restart my_api`
  (and `sudo -u my_api ./console migrate:rollback --force` if the new release ran migrations the old code cannot use).
* **HTTPS:** point DNS at the server, then `sudo certbot --nginx -d api.example.com`.
* **Logs / status:** `journalctl -u my_api -f`, `systemctl status my_api`.
* **Architecture:** `dartcore build` defaults to `--target linux-x64`; use `--target linux-arm64` for ARM servers
  (`uname -m` prints `aarch64`).
* **SQLite is not supported by `dartcore build`** (the `sqlite3` native build hook cannot be AOT-compiled with
  `dart compile exe`). Use PostgreSQL or MySQL, or run from source on the server.

What `install.sh` does, in order (each step prints `[n/9]`): checks root and the bundle; creates the `my_api` system user
(no login shell); creates `/opt/my_api` and a user-writable `storage/`; copies binaries atomically (keeping `.prev`); creates
`.env` only if missing (mode 600, owner = service user, `APP_ENV=production`, `APP_DEBUG=false`, generated secrets) and stops
until `DB_*` values are real; runs `console migrate` only with `--migrate`; installs/enables/restarts the systemd unit;
installs the nginx site only with `--nginx` (`nginx -t` before reload; sets `APP_TRUST_PROXY=true` and
`APP_HOST=127.0.0.1` in a newly created `.env`); then curls `/health` and prints the result. Failures print a plain-language
reason and are safe to retry.

### What was verified, and what was not

* **Run for real (macOS, Dart 3.13.4):** `dartcore create ... -d postgres --auth`, `deploy:init`, `dartcore build` for
  `linux-x64` and `linux-arm64` (ELF binaries: `server` about 9.6 MB, `console` about 7.6 MB, ~8 s total), `dartcore doctor`
  (config checks, console `doctor` command, failure reporting when no database is running), and the shell helpers
  (`get_env`, `set_env`, `missing_values`, secret-generation loop) extracted from `install.sh` and exercised with bash.
* **Automated tests:** generated file contents (unit fields, nginx, the no-overwrite-`.env` guard, secret generation),
  input validation, `bash -n` of `install.sh`, build argument handling with a fake compiler, SQLite refusal, doctor checks.
  A real cross-compile test exists but is opt-in (`DARTCORE_E2E_BUILD=1 dart test` in `packages/dartcore_cli`).
* **Not run:** `install.sh` was syntax-checked (`bash -n`; `shellcheck` was not installed here) and its logic unit-tested, but
  it was **not executed on a real Ubuntu host**; the produced Linux binaries were not executed either (no Linux machine
  available), nor was the systemd unit or nginx config loaded. Try it on a throwaway server first and report problems.
* The doctor database check needs a running database; it was run only against a closed port (failure path), and its success
  path is covered by a unit test against SQLite.

## Reference notes

1. **Compile.** `dartcore build` (or `dart compile exe bin/server.dart -o server`) produces a self-contained binary — *except* when the program
   depends on `sqlite3` (native build hook; `dart compile exe` rejects it — use `dart build cli` or choose PostgreSQL/MySQL).
   Otherwise run `dart run bin/server.dart` from source.
2. **Environment.** `APP_ENV=production` (also the default for unknown values), `APP_HOST=0.0.0.0`, `APP_PORT`, `DB_*`,
   `JWT_SECRET` (`openssl rand -base64 48`). Prefer your platform's secret store: `Config.load(sources: [DirectorySecretSource('/run/secrets')])`
   or your own `ConfigSource`. Do not ship `.env` in bundles or images.
3. **TLS.** DartCore serves HTTP. Terminate TLS at a reverse proxy/load balancer, enable
   `SecurityHeadersMiddleware(hsts: true)` and, if you rely on client IPs, set `APP_TRUST_PROXY=true` *only* when every request
   passes through a proxy you control.
4. **Database.** Run `dartcore migrate` as a deploy step (not at every instance boot; there is no migration lock). Size
   `DB_POOL_MAX` × instances below the database's connection limit. Use `DB_SSL=require` (or `verify-full`) for remote databases.
5. **Process.** Handle SIGTERM (built in): the server drains in-flight requests for up to 10 s and disconnects the database.
   Set your orchestrator's termination grace period above that. Expose a health check at `GET /health` (generated projects have one).
6. **Scaling.** One Dart isolate serves requests per process: scale with multiple processes/containers. The in-memory rate
   limiter, cache and auth stores are per process — use database-backed auth stores (`DatabaseAuthStores`) and a shared limiter
   if you run more than one instance.
7. **Logging.** `Log.use(Logger(handlers: [ConsoleHandler(json: true)]))` and ship stdout; production responses never contain
   stack traces, but logs do — protect them.
