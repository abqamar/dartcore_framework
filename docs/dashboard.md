# Monitoring dashboard (`dartcore_dashboard`)

A runtime dashboard for a **running DartCore app**: per-endpoint calls and latency, error issues, logs and a stacked time chart.
It is a single package you attach to any `DartCore`/`App`; the UI is one self-contained page (no external scripts, fonts or CDNs).

```dart
final app = DartCore();
Dashboard.attach(app, token: Config.require('DASHBOARD_TOKEN'));   // >= 16 chars
await app.start();
// open http://127.0.0.1:8080/_dashboard and enter the token
```
Try it with traffic: `cd examples/basic_api && dart run bin/dashboard_demo.dart`, then open `http://127.0.0.1:8090/_dashboard`.

## What you see
* **Dashboard**: requests, requests/min, error rate (5xx), typical and slow latency, open issues, chart, top endpoints.
* **Endpoints**: search + method filter, chart (total time / calls / errors, five heaviest endpoints plus "Other"), and a sortable table with
  **Calls · Typical (median) · Slow (p95) · Awful (p99) · 5xx · Impact**.
* **Issues**: unhandled errors grouped by type + route + top stack frame, with count, last seen, stack trace and recent request ids.
* **Logs**: the app's structured logs (already redacted by `dartcore_logging`), filter by level and text.
* Range: 15 min, 1 h, 6 h, 24 h. Auto-refresh 5 s / 15 s. Light and dark theme.

**Impact** is a heuristic, not a measurement: *Bad* if p95 > 3 s or > 5% of calls returned 5xx; *Medium* if p95 > 1 s, or the endpoint uses over
25% of all request time and its p95 exceeds 200 ms; otherwise *Good*.

## Security (read before enabling)
The dashboard shows logs, error messages and stack traces, so:
* Data endpoints (`/_dashboard/api/*`) always require authorization. Order of decision: your `authorize: (Request) => bool` callback; else the
  `token` (sent as `Authorization: Bearer …` or `X-Dashboard-Token`, compared in constant time; **never accepted in the URL**); else loopback-only
  (and never when `trustProxy` is on, because `X-Forwarded-For` is spoofable).
* **In production, `Dashboard.attach` throws unless you pass a token or `authorize`.**
* The HTML shell is served without credentials (it contains no data) with a strict CSP (`default-src 'none'`), `X-Frame-Options: DENY`, `no-store`.
* Only route *patterns* are recorded (`/users/:id`), never raw ids or query strings. All text shown is HTML-escaped (error messages and logs are untrusted).
* Serve it over HTTPS behind your proxy; consider restricting `/_dashboard` to your VPN/office network as well.

## How it works (and limits)
* `App.observe` (new in `dartcore_api`) delivers a `RequestRecord` per request: route pattern, status, duration, request id, error and stack.
* Everything is **in memory and per process**: bounded ring buffers (default 50,000 requests, 24 h, 5,000 logs, 500 issues), lost on restart.
  Percentiles are exact for the selected window because they are computed from the retained samples. Run several instances → each has its own dashboard.
* Duration is time to a ready response (for streamed bodies: until the headers).
* Not implemented (unlike the reference product): traces/spans, DB query timings, background-job view, profiles, alerts, custom metrics, persistence.
