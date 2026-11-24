import 'dart:async';

import '../request.dart';
import '../response.dart';

/// A request handler.
typedef Handler = FutureOr<Response> Function(Request request);

/// Wraps a [Handler]. Call `next(request)` to continue down the chain; return
/// a response without calling it to short-circuit.
///
/// Execution order is predictable: global middleware (in `app.use` order),
/// then group middleware (outer group first), then route middleware, then the
/// handler. Responses travel back through the same chain in reverse.
abstract class Middleware {
  const Middleware();

  /// Creates a middleware from a function.
  factory Middleware.from(
    FutureOr<Response> Function(Request request, Handler next) fn,
  ) => _FnMiddleware(fn);

  FutureOr<Response> handle(Request request, Handler next);
}

class _FnMiddleware extends Middleware {
  const _FnMiddleware(this._fn);
  final FutureOr<Response> Function(Request, Handler) _fn;
  @override
  FutureOr<Response> handle(Request request, Handler next) =>
      _fn(request, next);
}

/// Composes [middleware] around [handler]; the first element runs first.
Handler compose(List<Middleware> middleware, Handler handler) {
  var h = handler;
  for (final m in middleware.reversed) {
    final next = h;
    h = (req) => m.handle(req, next);
  }
  return h;
}
