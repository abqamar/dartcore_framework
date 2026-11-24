## 0.1.0

- `Config` facade and `ConfigRepository`: `.env` loading with `.env.<APP_ENV>` layering, process environment override, typed getters (`getInt`, `getBool`, `getDouble`, `require`).
- Pluggable `ConfigSource`s: `DotEnvSource` and `DirectorySecretSource` for mounted secrets.
- `AppEnvironment` (development, testing, staging, production).
- Typed exceptions with HTTP status codes: validation, authentication, authorization, not found, configuration, database, connection and query errors, and `HttpStatusException`.

First release.
