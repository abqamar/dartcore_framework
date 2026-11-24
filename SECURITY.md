# Security

Controls below are **implemented and covered by tests** unless marked otherwise. To report a vulnerability, do not open a
public issue; contact the maintainers privately (set a contact address before publishing).

## SQL injection

* Every value is a bound parameter (`$1` / `?`). Values never appear in SQL text
  (`query_builder_test.dart: values never appear in SQL text`; end-to-end on real engines in
  `integration_tests: SQL injection is inert`).
* Every identifier (table, column, alias, join column, `groupBy`, `orderBy`) is validated against
  `^[A-Za-z_][A-Za-z0-9_$]*` (dotted) and then quoted; anything else throws `QueryException` (tested with hostile inputs).
* Operators come from a whitelist. `ILIKE` is rejected on engines without it.
* **Raw SQL is explicit and advanced:** `whereRaw`, `selectRaw`, `havingRaw`, `DB.select`, `DB.statement`. They accept `?`
  placeholders for values; never concatenate user input into the SQL string. The placeholder scanner skips quoted literals.
  A `?` operator inside PostgreSQL JSON expressions is not supported by this scanner.
* Request-driven sort columns must go through `orderByAllowed(column, whitelist)`.
* `update()` / `delete()` / `increment()` without a `where` throw unless `allowAll: true`. `truncate()` is a separate call.
* DDL (`Schema`) cannot bind parameters; identifiers are validated, defaults are escaped, FK actions are whitelisted. Treat
  migration code as developer-controlled.
* There is no endpoint, helper or CLI command that executes arbitrary SQL from a request.

## Authentication (`dartcore_auth`)

* Passwords: **Argon2id** (OWASP minimum 19 MiB / t=2 / p=1) in PHC format with per-hash random salt, constant-time compare,
  `needsRehash`, and a cap on cost parameters read from a stored hash (prevents memory-exhaustion via a tampered hash).
  Implementation is `package:cryptography` (pure Dart, so slow per hash; hash only at login/register).
* JWT: HS256 only. The header is checked *before* the library sees the token, so `alg: none`, `HS512`, `RS256` are rejected.
  `iss`, `aud`, `exp` verified; `jti` required; secret must be ≥ 32 bytes and not a known placeholder (`replace_me`…).
* Refresh tokens: opaque 256-bit random, stored only as SHA-256, **single-use with rotation**. Presenting a used or revoked
  token revokes the whole family (replay detection); expired/unknown tokens fail. Logout revokes the access token's `jti`
  and the refresh family.
* API tokens (`dc_…`) and password-reset tokens are stored hashed; reset tokens are single-use, expire, and compare in constant time.
* Cookies (`Response.cookie`): `HttpOnly`, `Secure`, `SameSite` set by default; names/values are validated against header injection.
* Login in the generated project returns the same error for unknown user and wrong password.
* Tokens, passwords, cookies and authorization headers are redacted by the logger (key-based, recursive).

**Gaps / your responsibility**
* Roles in an access token are stale until it expires (15 min default). With a `UserRepository` configured, roles are
  re-read per request.
* Cookie-based auth needs CSRF protection for unsafe methods; DartCore sets `SameSite=Strict` for its token cookies but
  ships no CSRF-token middleware.
* There is no account lockout and no MFA. Add `RateLimitMiddleware` to login routes (the generated project does).
* In-memory auth stores lose revocations on restart; use `DatabaseAuthStores` in production.

## HTTP

* Body limits: 1 MiB (JSON/form/text) and 10 MiB (multipart) by default, enforced from `Content-Length` and while streaming;
  413 on excess. Bodies are buffered once so they can be read repeatedly.
* Multipart: filenames are reduced to a bare name (no `../`); **content is not scanned or type-checked**: validate type/size and
  store under a generated name.
* `request.ip` ignores `X-Forwarded-For` unless `trustProxy: true`.
* CORS: allowing credentials with a wildcard origin is refused at construction; preflight from unlisted origins gets 403.
* `SecurityHeadersMiddleware`: `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`, COOP/CORP, strict CSP for APIs, optional HSTS.
* Rate limiting is fixed-window and **per process** (not shared between instances).
* `Response.redirect` does not validate the target: never pass user input to it.
* Errors: 5xx responses contain only `Internal server error` in production (tested); `debug` (default only in development)
  adds the error text and a truncated stack trace. Stack traces and SQL are never sent otherwise; bound parameters are never
  stored in exceptions.
* Request ids from clients are accepted only if they match `^[A-Za-z0-9._-]{8,64}$`.
* The server speaks plain HTTP: terminate TLS at a reverse proxy/load balancer.

## Configuration and secrets

* `.env` is git-ignored in generated projects; `.env.example` has no secrets; the CLI generates a random `JWT_SECRET`.
* Precedence: explicit override > process environment > `ConfigSource`s > `.env.<APP_ENV>` > `.env`.
  Implement `ConfigSource` to load from Vault/AWS Secrets Manager/Docker secrets (`DirectorySecretSource` included).
* An unknown `APP_ENV` is treated as **production**, so a typo never enables debug output.
* `ConnectionConfig.toString()` never prints the password.

## CLI

* Names are validated (`^[A-Za-z][A-Za-z0-9_-]*`), so `create ../x` and `make:model ../../x` cannot write outside the target
  (tested). Generators never overwrite existing files.
* Destructive migration commands (`migrate:reset`, `migrate:fresh`, `migrate:rollback`) ask for confirmation and **refuse in
  production unless `--force`**. `Migrator.reset/fresh` throw unless `confirm: true`.

## Known limitations

Pure-Dart Argon2 speed; no streaming uploads; no built-in CSRF tokens; no per-query row-level authorization (Supabase RLS
is not integrated); the dependency set has not been audited (`dart pub outdated` / advisories should run in CI).
