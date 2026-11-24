# Roadmap

Honest status first: see [docs/status.md](docs/status.md). Items are ordered by value to a first real user.

## Next (0.2)

1. **SQL Server adapter.** Install FreeTDS in CI, build `dartcore_mssql` on `mssql_connection`'s native parameter path, add
   type conversion for its JSON results, run the shared contract suite against a SQL Server container. Resolve TLS/auth
   questions listed in the spike.
2. **OpenAPI** (`dartcore_openapi`): route metadata → OpenAPI 3.1, `/api/docs` (Swagger UI) and `/api/openapi.json`, disabled
   by default in production; wire up `dartcore docs:generate`.
3. **Storage** (`dartcore_storage`): local disk (path-traversal-safe, size/type validation, signed URLs), then S3-compatible.
4. **Redis cache** adapter behind `CacheStore`.
5. **Publish**: pick a license, fill package metadata (`homepage`, `repository`, `topics`), remove `publish_to: none`,
   `dart pub publish --dry-run` per package, version policy.

## Later

* Supabase services package (Auth, Storage, Realtime, REST/RPC) **separate from the SQL adapter contract**; verify against the
  Supabase CLI local stack; document RLS behaviour and key handling.
* Model code generation (`dartcore_orm_generator`) to remove `toMap`/`fillFromMap` boilerplate.
* Streaming result sets and request bodies; prepared-statement reuse; migration locking; per-driver query cancellation.
* Shared rate limiter/session stores; CSRF middleware; background job extension point.
* MariaDB in the contract suite; PostgreSQL schema/search-path options.
* Hot-reload `dartcore serve --watch`.

## Out of scope (for now)

WebSockets beyond what Shelf offers directly, GraphQL, multi-database distributed transactions (DartCore will never imply they
are atomic).
