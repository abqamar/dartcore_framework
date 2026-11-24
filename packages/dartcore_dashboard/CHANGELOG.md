## 0.1.0

- `Dashboard.attach(app, ...)` serves a self-contained monitoring UI at `/_dashboard` (configurable base path).
- Per-endpoint calls, median / p95 / p99 latency, 5xx counts and an impact heuristic; summary and time series for 15 min to 24 h.
- Error issues grouped by type, route and top stack frame; log viewer fed by `dartcore_logging`.
- Access control through `authorize` callback, bearer token or loopback-only; refuses to attach in production without one.
- Strict CSP, HTML escaping of all displayed text and route patterns instead of raw paths.

First release.
