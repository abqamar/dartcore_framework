/// Request-level tracing hooks, used by monitoring tools such as
/// `dartcore_dashboard`.
library;

/// Attribute key under which the per-request [RequestTrace] is stored.
const String traceKey = 'dartcore.trace';

/// Mutable scratch space shared by everything that handles one request. The
/// router fills in [route]; the exception middleware fills in [error].
class RequestTrace {
  /// The matched route pattern (`/users/:id`), or null when nothing matched.
  String? route;

  /// The unhandled exception behind a 500, if any.
  Object? error;
  StackTrace? stackTrace;
}

/// A finished request, delivered to observers registered with `App.observe`.
class RequestRecord {
  RequestRecord({
    required this.time,
    required this.method,
    required this.path,
    required this.route,
    required this.status,
    required this.duration,
    required this.ip,
    this.requestId,
    this.error,
    this.stackTrace,
  });

  /// When the request started (UTC).
  final DateTime time;
  final String method;

  /// Raw request path without the query string (query strings often carry tokens).
  final String path;

  /// Matched route pattern; null for unmatched (404/405) requests.
  final String? route;
  final int status;

  /// Time until the response was ready (for streamed bodies: until the headers).
  final Duration duration;
  final String ip;
  final String? requestId;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Called after each request. Exceptions thrown by an observer are swallowed
/// so monitoring can never break request handling.
typedef RequestObserver = void Function(RequestRecord record);
