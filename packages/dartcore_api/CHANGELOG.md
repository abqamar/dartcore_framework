## 0.1.0

- `App` with routing (params, wildcards, groups, named routes, 405/OPTIONS/HEAD handling) on top of Shelf.
- `Request` helpers for JSON, form and multipart bodies with enforced limits; `Response` constructors including the success/error envelope.
- Built-in middleware: request id, logger, timing, CORS, rate limit (per process), security headers, maintenance mode, compression and exception mapping.
- Per-route handler timeouts and graceful shutdown with a grace period and shutdown hooks.
- `app.send` for socket-free testing and `app.observe` request observers (used by `dartcore_dashboard`).

First release.
