# dartcore_api

HTTP routing, request/response helpers and middleware (CORS, rate limit, security headers, timeouts) for DartCore, built on Shelf.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. `dartcore_framework` re-exports this package.

## Install

```sh
dart pub add dartcore_api
```

## Usage

```dart
import 'package:dartcore_api/dartcore_api.dart';

Future<void> main() async {
  final app = App();

  app.use(CorsMiddleware(allowedOrigins: ['https://app.example.com']));
  app.use(RateLimitMiddleware(maxRequests: 100, duration: const Duration(minutes: 1)));

  app.get('/hello/:name', (request) =>
      Response.success({'greeting': 'Hello, ${request.param('name')}!'}));

  app.group('/api/v1', routes: () {
    app.post('/echo', (request) async => Response.created(await request.json()));
  });

  await app.start(port: 8080);     // SIGINT/SIGTERM trigger a graceful shutdown
}
```

- Path parameters (`:id`), a trailing `*` wildcard, nested groups, named routes and per-route timeouts.
- Body readers: `json()`, `form()`, `multipart()`, `files()`, with enforced size limits (413).
- Responses: `Response.ok`, `created`, `success`, `error`, `notFound`, `validationError`, `text`, `html`, `redirect`, `file`, `stream`.
- Throw `ValidationException`, `NotFoundException` and friends from `dartcore_core` and they become 422 / 404 / ... responses; other errors become a generic 500.
- `app.send('GET', '/path')` runs a request through the whole pipeline without a socket, which is handy in tests.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_api/example/dartcore_api_example.dart) starts a server on a free port and calls it.

## Status and limits

Pre-1.0: the API may change. Request bodies are buffered in memory (multipart uploads default to a 10 MiB limit).
A handler timeout returns 504 but does not cancel the running work. `RateLimitMiddleware` is per process, so
several instances do not share counters. See the [HTTP guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/http.md) and the
[middleware guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/middleware.md).
