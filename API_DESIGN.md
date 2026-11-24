# API design

Principle: **simplicity is the product.** Short names, sensible defaults, explicit escape hatches.

## Response contract

Success envelope (`Response.success(data, message:, meta:, status:)`):

```json
{ "success": true, "message": "Users retrieved successfully", "data": [], "meta": null }
```

Error envelope (`Response.error`, `badRequest`, `unauthorized`, `forbidden`, `notFound`, `serverError`):

```json
{ "success": false, "message": "User not found" }
```

Validation (`Response.validationError(errors)`, status 422):

```json
{ "success": false, "message": "Validation failed", "errors": { "email": ["The email field is required."] } }
```

`Response.ok(data)` / `Response.created(data)` send `data` **as-is** (matching the vision example
`Response.ok(users)`). Error helpers also accept a `Map`, which is sent as-is
(`Response.notFound({'message': 'User not found'})`). Other bodies: `text`, `html`, `redirect`, `download`, `file`,
`stream`, `noContent`; modifiers `withHeader`, `cookie`, `clearCookie`.

## Request

`param('id')`, `query('q')`, `queryAll`, `header(name)` (case-insensitive), `cookie(name)`, `method`, `path`, `ip`,
`attributes` (per-request map for middleware), `text()`, `json()` (object; 400 otherwise), `jsonAny()`, `form()`,
`body()` (by content type), `multipart()`, `files()`, `bytes()`. Body accessors share one buffer.

## Routing

`app.get/post/put/patch/delete/options/head(path, handler, {middleware, name, timeout})`; `:param` and trailing `*`;
`app.group(prefix, middleware:, routes: () {...})` (nestable); `app.url('users.show', {'id': 1})`; automatic `405` with
`Allow`, automatic `OPTIONS`, `HEAD` falls back to `GET`; duplicate routes/names throw at registration.
A handler timeout returns 504 but cannot cancel the Dart work already running.

## Deviations from the vision, and why

| Vision | Implemented | Reason |
|---|---|---|
| `DB.connect` works with only `import 'package:dartcore_framework/dartcore_framework.dart'` | also call `registerPostgres()` | adapters are separate packages |
| `Validate.request(request.json(), …)` | `Validate.request(await request.json(), …)` | `json()` is async |
| `user.hasMany(Post)` (a `Type`) | `user.hasMany(Post.new)` | no reflection in compiled Dart |
| `User.find(1)` inherited static | one-line static wrappers on the model (generated) | Dart statics are not inherited |
| `Auth.middleware()` etc. | same; resolves the service lazily at request time | allows route listing before Auth is configured |
| adapter `beginTransaction/commit/rollback` | `transaction(callback)` | prevents leaked transactions on a shared pool |
| `Storage`, `Cache.put` with Redis, OpenAPI | `Cache` in-memory only; Storage/OpenAPI absent | see [docs/status.md](docs/status.md) |

## Stability

Pre-1.0: anything may change between minor versions. From 1.0, public APIs follow semantic versioning and every change is
recorded in [CHANGELOG.md](CHANGELOG.md). Public APIs never expose driver or Shelf types (except the explicit
`Request.toShelf()` escape hatch).
