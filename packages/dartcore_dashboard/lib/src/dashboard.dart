import 'dart:convert';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';

import 'collector.dart';
import 'ui.dart';

/// Attaches the monitoring dashboard to an [App].
///
/// ```dart
/// Dashboard.attach(app, token: Config.require('DASHBOARD_TOKEN'));
/// ```
///
/// **Access control.** The dashboard exposes logs, error messages and stack
/// traces, so its data endpoints are always guarded:
///  * [authorize], if given, decides (return `true` to allow);
///  * otherwise a [token] (sent as `Authorization: Bearer <token>`) is required;
///  * with neither, only loopback clients are allowed, and only when the app is
///    not in production and does not trust proxy headers.
/// In production, attaching without [token] or [authorize] throws.
/// Only the static HTML shell is served without credentials; it contains no data.
class Dashboard {
  Dashboard._(this.collector, this.basePath, this._authorize);

  final Collector collector;
  final String basePath;
  final bool Function(Request request) _authorize;

  factory Dashboard.attach(
    App app, {
    String basePath = '/_dashboard',
    String? token,
    bool Function(Request request)? authorize,
    DashboardOptions options = const DashboardOptions(),
    String? title,
  }) {
    final base = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    if (!base.startsWith('/')) {
      throw ArgumentError('basePath must start with "/".');
    }
    if (token != null && token.length < 16) {
      throw ConfigurationException(
        'The dashboard token must be at least 16 characters.',
      );
    }
    final hasAuth = token != null || authorize != null;
    if (!hasAuth && app.config.environment.isProduction) {
      throw ConfigurationException(
        'Refusing to expose the dashboard in production without a token or an authorize callback.',
      );
    }

    bool allowed(Request r) {
      if (authorize != null) return authorize(r);
      if (token != null) {
        final h = r.header('authorization');
        final given =
            h != null &&
                h.length > 7 &&
                h.substring(0, 7).toLowerCase() == 'bearer '
            ? h.substring(7).trim()
            : r.header('x-dashboard-token');
        return given != null && _constantTimeEquals(given, token);
      }
      // Local development default: loopback only, never behind a trusted proxy.
      return !app.config.trustProxy && (r.ip == '127.0.0.1' || r.ip == '::1');
    }

    final collector = Collector(options);
    final dash = Dashboard._(collector, base, allowed);
    app.observe((rec) {
      if (rec.path == base || rec.path.startsWith('$base/')) {
        return; // do not monitor the monitor
      }
      collector.record(rec);
    });
    // The request logger prints "METHOD /path status"; skip those lines for the dashboard's own routes.
    final selfLine = RegExp('^[A-Z]+ ${RegExp.escape(base)}(/|\\s)');
    app.logger.handlers.add(
      DashboardLogHandler(
        collector,
        ignore: (r) => selfLine.hasMatch(r.message),
      ),
    );
    dash._register(app, title ?? app.config.name);
    return dash;
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static const _ranges = {
    '15m': Duration(minutes: 15),
    '1h': Duration(hours: 1),
    '6h': Duration(hours: 6),
    '24h': Duration(hours: 24),
  };

  Duration _range(Request r) =>
      _ranges[r.query('range') ?? '1h'] ??
      (throw HttpStatusException(
        400,
        'range must be one of ${_ranges.keys.join(', ')}.',
      ));

  void _register(App app, String title) {
    Response guarded(Request r, Object? Function() body) {
      if (!_authorize(r)) {
        return Response.error(
          'Unauthorized',
          status: 401,
        ).withHeader('www-authenticate', 'Bearer');
      }
      return Response.json(body(), headers: {'cache-control': 'no-store'});
    }

    app.get(
      basePath,
      (r) => Response.html(
        dashboardHtml(title, basePath),
        headers: {
          'cache-control': 'no-store',
          'content-security-policy':
              "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:",
          'x-frame-options': 'DENY',
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
        },
      ),
    );
    app.get(
      '$basePath/api/summary',
      (r) => guarded(r, () => collector.summary(_range(r))),
    );
    app.get(
      '$basePath/api/endpoints',
      (r) => guarded(
        r,
        () => [
          for (final e in collector.endpoints(
            _range(r),
            search: r.query('search'),
            method: r.query('method'),
          ))
            e.toJson(),
        ],
      ),
    );
    app.get(
      '$basePath/api/series',
      (r) => guarded(r, () {
        try {
          return collector.series(
            _range(r),
            metric: r.query('metric') ?? 'total_time',
          );
        } on ArgumentError catch (e) {
          throw HttpStatusException(400, '${e.message}');
        }
      }),
    );
    app.get(
      '$basePath/api/issues',
      (r) => guarded(r, () => collector.issues(search: r.query('search'))),
    );
    app.get(
      '$basePath/api/logs',
      (r) => guarded(
        r,
        () => collector.logs(
          level: r.query('level'),
          search: r.query('search'),
          requestId: r.query('request_id'),
          limit: (int.tryParse(r.query('limit') ?? '') ?? 200).clamp(1, 1000),
        ),
      ),
    );
  }
}
