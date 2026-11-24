# dartcore_dashboard

A runtime monitoring dashboard for DartCore apps: endpoints, latency percentiles, issues and logs, served from inside your app.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub add dartcore_dashboard
```

## Usage

```dart
import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_dashboard/dartcore_dashboard.dart';

Future<void> main() async {
  final app = App();
  Dashboard.attach(app, token: Config.require('DASHBOARD_TOKEN'));   // at least 16 characters
  await app.start();
  // open http://127.0.0.1:8080/_dashboard and enter the token
}
```

The page shows requests, error rate, typical / slow / awful latency (median, p95, p99), a time chart, per-endpoint stats,
grouped error issues with stack traces, and the app's structured logs. It is one self-contained page with no external scripts or fonts.

## Security

The dashboard exposes logs and stack traces, so its data endpoints always require authorization: your `authorize` callback,
else the `token` (as `Authorization: Bearer` or `X-Dashboard-Token`, never in the URL), else loopback only.
**In production `Dashboard.attach` throws unless you pass a token or `authorize`.** Only route patterns are recorded, never raw ids
or query strings. Serve it over HTTPS and consider restricting it to a private network.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_dashboard/example/dartcore_dashboard_example.dart) reads its data API in-process.

## Status and limits

Pre-1.0: the API may change. All data is in memory and per process (bounded buffers, lost on restart; each instance has its
own dashboard). The "Impact" label is a heuristic, not a measurement. Not implemented: traces, database query timings,
background jobs, alerts, custom metrics, persistence. See the [dashboard guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/dashboard.md).
