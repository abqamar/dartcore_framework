# HTTP: routing, requests, responses

```dart
final app = DartCore();

app.get('/users/:id', (request) async {
  final id = request.param('id');           // route param
  final search = request.query('search');   // ?search=
  final auth = request.header('Authorization');
  ...
}, name: 'users.show', timeout: const Duration(seconds: 5));

app.group('/api/v1', middleware: [Auth.middleware()], routes: () {
  app.get('/me', meHandler);
  app.group('/admin', middleware: [Auth.role(['admin'])], routes: () {
    app.get('/stats', statsHandler);       // GET /api/v1/admin/stats, both middleware apply
  });
});

app.url('users.show', {'id': 5});           // '/users/5'
```

* Methods: `get post put patch delete options head`, plus `match([...methods], path, handler)`.
* `405 Method Not Allowed` includes `Allow`; `OPTIONS` is answered automatically when a path exists; `HEAD` falls back to `GET`.
* `*` at the end of a path captures the rest: `app.get('/files/*', (r) => r.param('*'))`.
* Duplicate routes or route names throw `StateError` at registration.

## Request body

```dart
final data = await request.json();           // Map, 400 if malformed / not an object
final any  = await request.jsonAny();        // lists allowed
final form = await request.form();           // x-www-form-urlencoded
final body = await request.body();           // picks JSON / form / multipart by Content-Type; 415 otherwise
final m    = await request.multipart();      // (fields: ..., files: [UploadedFile])
for (final f in await request.files()) { f.field; f.filename; f.contentType; f.size; f.extension; f.bytes; }
```

Limits (`AppConfig(limits: BodyLimits(maxBodyBytes: 1 << 20, maxUploadBytes: 10 << 20))`) are enforced from
`Content-Length` and while reading; excess → 413. The body is buffered once, so calling `json()` then `text()` is fine.
`UploadedFile.filename` has directories stripped, but **you** must validate type/size and choose the stored name.

## Responses

```dart
Response.ok(data)                    // JSON as-is
Response.created(data)               // 201
Response.success(data, message: 'Done', meta: {...}, status: 200)   // envelope
Response.error('msg', status: 409)   // {"success": false, "message": ...}
Response.badRequest() unauthorized() forbidden() notFound('x') serverError()
Response.notFound({'message': 'User not found'})      // a Map is sent as-is
Response.validationError({'email': ['Required']})     // 422 envelope
Response.noContent()
Response.text('hi') / html('<b>') / redirect('/x') / download(bytes, 'a.pdf') / file(path) / stream(stream)
res.withHeader('x-a', '1').cookie('sid', token, maxAge: Duration(days: 7))   // HttpOnly+Secure+SameSite=Lax by default
```

JSON encoding understands `DateTime` (UTC ISO-8601), `BigInt`, `Duration`, and any object with `toJson()`.

## Errors

Throw instead of returning when convenient: `ValidationException` → 422, `AuthenticationException` → 401,
`AuthorizationException` → 403, `NotFoundException` → 404, `HttpStatusException(status, message)`, and any other error → 500
with the generic message `Internal server error` (details only in development, always logged with the request id).

## Server lifecycle

`await app.start(port: 8080)` installs SIGINT/SIGTERM handlers; shutdown stops accepting connections, lets in-flight
requests finish for `AppConfig.shutdownGracePeriod` (10 s), then forces the rest closed and runs `app.onShutdown` hooks
(`DartCore` registers one that disconnects its database).
