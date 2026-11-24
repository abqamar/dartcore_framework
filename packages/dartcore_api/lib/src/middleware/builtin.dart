import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_logging/dartcore_logging.dart';

import '../request.dart';
import '../response.dart';
import '../observer.dart';
import 'middleware.dart';

final _rng = Random.secure();

String _randomHex(int bytes) => List.generate(
  bytes,
  (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Assigns every request an id (`X-Request-Id` is reused if it is a short,
/// safe token), exposes it as `request.attributes['request_id']`, tags all
/// logs emitted while handling the request, and echoes it on the response.
class RequestIdMiddleware extends Middleware {
  const RequestIdMiddleware();

  @override
  FutureOr<Response> handle(Request request, Handler next) {
    final incoming = request.header('x-request-id');
    final id =
        incoming != null && RegExp(r'^[A-Za-z0-9._-]{8,64}$').hasMatch(incoming)
        ? incoming
        : _randomHex(8);
    request.attributes['request_id'] = id;
    return runWithRequestId(id, () async {
      final res = await next(request);
      return res.withHeader('x-request-id', id);
    });
  }
}

/// Logs `METHOD path status duration`. Only the *path* is logged (query strings
/// frequently carry tokens).
class LoggerMiddleware extends Middleware {
  LoggerMiddleware([Logger? logger]) : _logger = logger;
  final Logger? _logger;

  @override
  Future<Response> handle(Request request, Handler next) async {
    final sw = Stopwatch()..start();
    final log = _logger ?? Log.instance;
    try {
      final res = await next(request);
      log.info(
        '${request.method} ${request.path} ${res.statusCode}',
        context: {'duration_ms': sw.elapsedMilliseconds, 'ip': request.ip},
      );
      return res;
    } catch (e) {
      log.warning(
        '${request.method} ${request.path} failed',
        context: {'duration_ms': sw.elapsedMilliseconds},
        error: e,
      );
      rethrow;
    }
  }
}

/// Adds `X-Response-Time`.
class TimingMiddleware extends Middleware {
  const TimingMiddleware();
  @override
  Future<Response> handle(Request request, Handler next) async {
    final sw = Stopwatch()..start();
    final res = await next(request);
    return res.withHeader('x-response-time', '${sw.elapsedMilliseconds}ms');
  }
}

class CorsMiddleware extends Middleware {
  CorsMiddleware({
    this.allowedOrigins = const ['*'],
    this.allowedMethods = const [
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'OPTIONS',
      'HEAD',
    ],
    this.allowedHeaders = const [
      'Content-Type',
      'Authorization',
      'X-Request-Id',
    ],
    this.exposedHeaders = const [],
    this.allowCredentials = false,
    this.maxAge = const Duration(hours: 1),
  }) {
    if (allowCredentials && allowedOrigins.contains('*')) {
      throw ArgumentError(
        'CORS: allowCredentials cannot be combined with a wildcard origin. '
        'List the exact origins instead.',
      );
    }
  }

  final List<String> allowedOrigins,
      allowedMethods,
      allowedHeaders,
      exposedHeaders;
  final bool allowCredentials;
  final Duration maxAge;

  bool get _wildcard => allowedOrigins.contains('*');

  @override
  Future<Response> handle(Request request, Handler next) async {
    final origin = request.header('origin');
    if (origin == null) return next(request);
    final allowed = _wildcard || allowedOrigins.contains(origin);

    final isPreflight =
        request.method == 'OPTIONS' &&
        request.header('access-control-request-method') != null;
    if (isPreflight) {
      if (!allowed) return Response(403, body: '');
      return _decorate(
        Response(
          204,
          headers: {
            'access-control-allow-methods': allowedMethods.join(', '),
            'access-control-allow-headers': allowedHeaders.join(', '),
            'access-control-max-age': '${maxAge.inSeconds}',
          },
        ),
        origin,
      );
    }
    final res = await next(request);
    return allowed ? _decorate(res, origin) : res;
  }

  Response _decorate(Response res, String origin) {
    var r = res.withHeader(
      'access-control-allow-origin',
      _wildcard ? '*' : origin,
    );
    if (!_wildcard) r = r.withHeader('vary', 'Origin');
    if (allowCredentials) {
      r = r.withHeader('access-control-allow-credentials', 'true');
    }
    if (exposedHeaders.isNotEmpty) {
      r = r.withHeader(
        'access-control-expose-headers',
        exposedHeaders.join(', '),
      );
    }
    return r;
  }
}

/// Fixed-window, in-memory, per-key rate limiter (default key: client IP).
/// State is per process: behind multiple instances use a shared store.
class RateLimitMiddleware extends Middleware {
  RateLimitMiddleware({
    required this.maxRequests,
    required this.duration,
    String Function(Request request)? keyBuilder,
    DateTime Function()? clock,
  }) : _key = keyBuilder ?? ((r) => r.ip),
       _now = clock ?? DateTime.now;

  final int maxRequests;
  final Duration duration;
  final String Function(Request) _key;
  final DateTime Function() _now;
  final Map<String, _Window> _windows = {};

  @override
  Future<Response> handle(Request request, Handler next) async {
    final now = _now();
    if (_windows.length > 10000) {
      _windows.removeWhere((_, w) => !w.resetAt.isAfter(now));
    }
    final key = _key(request);
    var w = _windows[key];
    if (w == null || !w.resetAt.isAfter(now)) {
      w = _windows[key] = _Window(now.add(duration));
    }
    w.count++;
    final remaining = max(0, maxRequests - w.count);
    final resetIn = max(1, w.resetAt.difference(now).inSeconds);
    final limitHeaders = {
      'x-ratelimit-limit': '$maxRequests',
      'x-ratelimit-remaining': '$remaining',
      'x-ratelimit-reset': '$resetIn',
    };
    if (w.count > maxRequests) {
      return Response.error('Too many requests', status: 429)
          .withHeader('retry-after', '$resetIn')
          .withHeader('x-ratelimit-limit', limitHeaders['x-ratelimit-limit']!)
          .withHeader('x-ratelimit-remaining', '0');
    }
    var res = await next(request);
    for (final e in limitHeaders.entries) {
      res = res.withHeader(e.key, e.value);
    }
    return res;
  }
}

class _Window {
  _Window(this.resetAt);
  final DateTime resetAt;
  int count = 0;
}

/// Adds conservative security headers to responses that do not set them.
class SecurityHeadersMiddleware extends Middleware {
  const SecurityHeadersMiddleware({
    this.hsts = false,
    this.contentSecurityPolicy = "default-src 'none'; frame-ancestors 'none'",
  });

  /// Enable only when the app is served over HTTPS.
  final bool hsts;
  final String? contentSecurityPolicy;

  @override
  Future<Response> handle(Request request, Handler next) async {
    var res = await next(request);
    void add(String k, String v) {
      if (res.header(k) == null) res = res.withHeader(k, v);
    }

    add('x-content-type-options', 'nosniff');
    add('x-frame-options', 'DENY');
    add('referrer-policy', 'no-referrer');
    add('cross-origin-opener-policy', 'same-origin');
    add('cross-origin-resource-policy', 'same-origin');
    if (contentSecurityPolicy != null) {
      add('content-security-policy', contentSecurityPolicy!);
    }
    if (hsts) {
      add('strict-transport-security', 'max-age=31536000; includeSubDomains');
    }
    return res;
  }
}

/// Responds 503 while [enabled] returns true (except for [allowPaths]).
class MaintenanceMiddleware extends Middleware {
  const MaintenanceMiddleware(
    this.enabled, {
    this.retryAfter = const Duration(minutes: 5),
    this.allowPaths = const ['/health'],
  });

  final bool Function() enabled;
  final Duration retryAfter;
  final List<String> allowPaths;

  @override
  FutureOr<Response> handle(Request request, Handler next) {
    if (enabled() && !allowPaths.contains(request.path)) {
      return Response.error(
        'Service temporarily unavailable for maintenance.',
        status: 503,
      ).withHeader('retry-after', '${retryAfter.inSeconds}');
    }
    return next(request);
  }
}

/// gzip-compresses buffered text/JSON responses when the client accepts it.
class CompressionMiddleware extends Middleware {
  const CompressionMiddleware({this.minBytes = 1024});
  final int minBytes;

  static final _compressible = RegExp(
    r'^(text/|application/(json|javascript|xml)|image/svg)',
  );

  @override
  Future<Response> handle(Request request, Handler next) async {
    final res = await next(request);
    final accept = request.header('accept-encoding') ?? '';
    final type = res.header('content-type') ?? '';
    if (!accept.contains('gzip') ||
        res.header('content-encoding') != null ||
        !_compressible.hasMatch(type) ||
        res.body is Stream) {
      return res;
    }
    final raw = await res.readBytes();
    if (raw.length < minBytes) return res;
    return Response(
      res.statusCode,
      body: gzip.encode(raw),
      headers: {
        for (final e in res.headers.entries)
          if (e.key != 'content-length') e.key: e.value,
        'content-encoding': 'gzip',
        'vary': 'Accept-Encoding',
      },
    );
  }
}

/// Converts exceptions into the standard JSON error envelope. Installed
/// automatically as the outermost middleware by the app.
///
/// In production nothing internal is exposed for 5xx errors. With
/// [debug] = true the error text and stack trace are included (development only).
class ExceptionMiddleware extends Middleware {
  const ExceptionMiddleware({this.debug = false, this.logger});
  final bool debug;
  final Logger? logger;

  @override
  Future<Response> handle(Request request, Handler next) async {
    try {
      return await next(request);
    } on ValidationException catch (e) {
      return Response.validationError(e.errors, message: e.message);
    } on HttpStatusException catch (e) {
      var r = Response.error(e.message, status: e.statusCode);
      for (final h in e.headers.entries) {
        r = r.withHeader(h.key, h.value);
      }
      return r;
    } on DartCoreException catch (e, st) {
      if (e.statusCode >= 500) return _internal(request, e, st);
      return Response.error(e.message, status: e.statusCode);
    } on FormatException catch (e) {
      return Response.error('Malformed request: ${e.message}', status: 400);
    } catch (e, st) {
      return _internal(request, e, st);
    }
  }

  Response _internal(Request request, Object e, StackTrace st) {
    final trace = request.attributes[traceKey];
    if (trace is RequestTrace) {
      trace.error = e;
      trace.stackTrace = st;
    }
    (logger ?? Log.instance).error(
      'Unhandled error in ${request.method} ${request.path}',
      error: e,
      stackTrace: st,
    );
    if (!debug) return Response.error('Internal server error', status: 500);
    return Response.json({
      'success': false,
      'message': 'Internal server error',
      'debug': {
        'error': e.toString(),
        'stack_trace': st.toString().split('\n').take(15).toList(),
      },
    }, status: 500);
  }
}
