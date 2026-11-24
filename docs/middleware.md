# Middleware

```dart
app.use(LoggerMiddleware());
app.use(CorsMiddleware(allowedOrigins: ['https://app.example.com'], allowCredentials: true));
app.use(RateLimitMiddleware(maxRequests: 100, duration: const Duration(minutes: 1)));
app.use(const SecurityHeadersMiddleware(hsts: true));         // hsts only behind HTTPS
```

| Middleware | Does |
|---|---|
| `RequestIdMiddleware` | adds/echoes `X-Request-Id`, tags logs (installed automatically) |
| `LoggerMiddleware` | `METHOD path status ms` (path only, never the query string) (installed automatically) |
| `TimingMiddleware` | `X-Response-Time` |
| `CorsMiddleware` | origins/methods/headers, preflight → 204 / 403, `Vary: Origin`; refuses credentials + `*` |
| `RateLimitMiddleware` | fixed window per key (default IP), `X-RateLimit-*`, 429 + `Retry-After`; per process |
| `SecurityHeadersMiddleware` | `nosniff`, frame deny, referrer policy, COOP/CORP, CSP, optional HSTS; never overrides handler headers |
| `MaintenanceMiddleware(() => flag)` | 503 + `Retry-After` except allow-listed paths (`/health`) |
| `CompressionMiddleware` | gzip for buffered text/JSON ≥ `minBytes` when the client accepts it |
| `ExceptionMiddleware` | exceptions → envelope; always outermost, installed automatically |

## Order

```
Exception → RequestId → Logger → global (app.use order) → group (outer→inner) → route → timeout → handler
```
Responses return in reverse. Put cheap rejections (rate limit, CORS) early (`app.use` them first), auth in groups/routes.

## Custom middleware

```dart
class ApiKeyMiddleware extends Middleware {
  const ApiKeyMiddleware(this.key);
  final String key;

  @override
  Future<Response> handle(Request request, Handler next) async {
    if (request.header('x-api-key') != key) return Response.unauthorized('Bad API key');   // short-circuit
    request.attributes['client'] = 'partner';                                              // share data downstream
    final response = await next(request);                                                  // continue
    return response.withHeader('x-served-by', 'dartcore');                                 // post-process
  }
}

app.use(const ApiKeyMiddleware('...'));
final quick = Middleware.from((request, next) async => next(request));                      // function form
app.get('/x', handler, middleware: [quick]);
```

Compare secrets with a constant-time comparison (`constantTimeEquals` in `dartcore_auth`) rather than `!=` in real code.
`dartcore make:middleware Name` generates a skeleton.
