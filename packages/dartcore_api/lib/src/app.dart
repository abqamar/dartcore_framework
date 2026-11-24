import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'json.dart';
import 'middleware/builtin.dart';
import 'middleware/middleware.dart';
import 'observer.dart';
import 'request.dart';
import 'response.dart';
import 'router.dart';

/// Immutable application settings. Every value has a sensible default and can
/// be loaded from configuration with [AppConfig.fromConfig].
class AppConfig {
  const AppConfig({
    this.name = 'DartCore',
    this.environment = AppEnvironment.development,
    this.host,
    this.port = 8080,
    this.debug,
    this.limits = const BodyLimits(),
    this.requestTimeout,
    this.trustProxy = false,
    this.shutdownGracePeriod = const Duration(seconds: 10),
    this.requestIdAndLogging = true,
  });

  /// Reads `APP_NAME`, `APP_ENV`, `APP_HOST`, `APP_PORT`, `APP_DEBUG`,
  /// `APP_TRUST_PROXY` from [config].
  factory AppConfig.fromConfig(ConfigRepository config) => AppConfig(
    name: config.get('APP_NAME', 'DartCore')!,
    environment: config.environment,
    host: config.get('APP_HOST'),
    port: config.getInt('APP_PORT', 8080),
    debug: config.has('APP_DEBUG') ? config.getBool('APP_DEBUG') : null,
    trustProxy: config.getBool('APP_TRUST_PROXY', false),
  );

  final String name;
  final AppEnvironment environment;

  /// Defaults to loopback in development/testing and all interfaces in
  /// staging/production (containers).
  final String? host;
  final int port;

  /// Include error details in 500 responses. Defaults to true only in
  /// development.
  final bool? debug;
  final BodyLimits limits;
  final Duration? requestTimeout;
  final bool trustProxy;
  final Duration shutdownGracePeriod;
  final bool requestIdAndLogging;

  bool get isDebug => debug ?? environment == AppEnvironment.development;
  String get effectiveHost =>
      host ??
      (environment.isDevelopment || environment == AppEnvironment.testing
          ? '127.0.0.1'
          : '0.0.0.0');
}

class _Frame {
  _Frame(this.prefix, this.middleware);
  final String prefix;
  final List<Middleware> middleware;
}

/// The HTTP application: routes, middleware and server lifecycle.
class App {
  App({this.config = const AppConfig(), Logger? logger})
    : logger = logger ?? Log.instance;

  final AppConfig config;
  final Logger logger;

  final Router _router = Router();
  final List<Middleware> _global = [];
  final List<_Frame> _frames = [];
  final List<Future<void> Function()> _shutdownHooks = [];

  HttpServer? _server;
  final List<StreamSubscription<ProcessSignal>> _signals = [];
  Completer<void>? _stopped;

  List<Route> get routes => List.unmodifiable(_router.routes);
  HttpServer? get server => _server;
  int? get port => _server?.port;

  // ---- middleware -------------------------------------------------------------

  /// Adds global middleware. They run in the order added, outermost first.
  void use(Middleware middleware) => _global.add(middleware);

  /// Runs [callback] when the server stops (close pools, flush logs...).
  void onShutdown(Future<void> Function() callback) =>
      _shutdownHooks.add(callback);

  // ---- routing ----------------------------------------------------------------

  Route route(
    String method,
    String path,
    Handler handler, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) {
    final prefix = _frames.map((f) => f.prefix).join();
    final groupMw = [for (final f in _frames) ...f.middleware];
    final r = Route.build(
      method,
      '$prefix${path.startsWith('/') || path.isEmpty ? path : '/$path'}',
      handler,
      middleware: [...groupMw, ...middleware],
      name: name,
      timeout: timeout,
    );
    _router.add(r);
    return r;
  }

  Route get(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'GET',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route post(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'POST',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route put(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'PUT',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route patch(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'PATCH',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route delete(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'DELETE',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route options(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'OPTIONS',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );
  Route head(
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) => route(
    'HEAD',
    path,
    h,
    middleware: middleware,
    name: name,
    timeout: timeout,
  );

  /// Registers the same handler for several methods.
  void match(
    List<String> methods,
    String path,
    Handler h, {
    List<Middleware> middleware = const [],
  }) {
    for (final m in methods) {
      route(m, path, h, middleware: middleware);
    }
  }

  /// Groups routes under [prefix] with shared [middleware]. Routes registered
  /// inside [routes] (via `app.get(...)` etc.) inherit both. Groups nest.
  void group(
    String prefix, {
    List<Middleware> middleware = const [],
    required void Function() routes,
  }) {
    _frames.add(
      _Frame(
        prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix,
        middleware,
      ),
    );
    try {
      routes();
    } finally {
      _frames.removeLast();
    }
  }

  /// URL for a named route: `app.url('users.show', {'id': 5})` -> `/users/5`.
  String url(String name, [Map<String, Object> params = const {}]) =>
      (_router.named(name) ?? (throw ArgumentError('Unknown route "$name".')))
          .urlFor(params);

  // ---- observation ----------------------------------------------------------------

  final List<RequestObserver> _observers = [];

  /// Registers [observer] to be called after every request (see [RequestRecord]).
  /// Observers are for monitoring: keep them fast and side-effect free.
  void observe(RequestObserver observer) => _observers.add(observer);

  Future<Response> _run(Request req) async {
    if (_observers.isEmpty) return _pipeline(req);
    final trace = RequestTrace();
    req.attributes[traceKey] = trace;
    final started = DateTime.now().toUtc();
    final sw = Stopwatch()..start();
    final res = await _pipeline(req);
    sw.stop();
    final record = RequestRecord(
      time: started,
      method: req.method,
      path: req.path,
      route: trace.route,
      status: res.statusCode,
      duration: sw.elapsed,
      ip: req.ip,
      requestId: req.attributes['request_id'] as String?,
      error: trace.error,
      stackTrace: trace.stackTrace,
    );
    for (final o in _observers) {
      try {
        o(record);
      } catch (_) {}
    }
    return res;
  }

  // ---- request pipeline ---------------------------------------------------------

  late final Handler _pipeline = _buildPipeline();

  Handler _buildPipeline() {
    final outer = <Middleware>[
      ExceptionMiddleware(debug: config.isDebug, logger: logger),
      if (config.requestIdAndLogging) ...[
        const RequestIdMiddleware(),
        LoggerMiddleware(logger),
      ],
      ..._global,
    ];
    return compose(outer, _dispatch);
  }

  Future<Response> _dispatch(Request request) async {
    final method = request.method;
    var m = _router.match(method, request.path);
    // HEAD falls back to GET (the server strips the body).
    if (m == null && method == 'HEAD') m = _router.match('GET', request.path);
    if (m == null) {
      final allowed = _router.allowedMethods(request.path);
      if (allowed.isNotEmpty) {
        if (method == 'OPTIONS') {
          return Response(
            204,
            headers: {
              'allow': ([...allowed, 'OPTIONS']..sort()).join(', '),
            },
          );
        }
        throw HttpStatusException(
          405,
          'Method not allowed.',
          headers: {'allow': (allowed.toList()..sort()).join(', ')},
        );
      }
      throw NotFoundException(
        'Route ${request.method} ${request.path} not found.',
      );
    }
    final req = request.withParams(m.params);
    final route = m.route;
    final trace = request.attributes[traceKey];
    if (trace is RequestTrace) trace.route = route.path;
    Handler h = route.handler;
    final timeout = route.timeout ?? config.requestTimeout;
    if (timeout != null) {
      final inner = h;
      h = (r) => Future<Response>.sync(() => inner(r)).timeout(
        timeout,
        onTimeout: () => throw HttpStatusException(504, 'Request timed out.'),
      );
    }
    return compose(route.middleware, h)(req);
  }

  /// Runs a request through the full pipeline without a network socket.
  /// Ideal for tests: `await app.send('GET', '/users')`.
  Future<Response> send(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final hdrs = {...?headers};
    List<int> bytes = const [];
    if (body is Uint8List) {
      // Raw bytes (uploads). A plain List<int> is a JSON array, so bytes must be a Uint8List.
      bytes = body;
    } else if (body is Map || body is List) {
      bytes = utf8.encode(encodeJson(body));
      hdrs.putIfAbsent('content-type', () => 'application/json');
    } else if (body is String) {
      bytes = utf8.encode(body);
    }
    final req = Request(
      shelf.Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: hdrs,
        body: bytes,
      ),
      limits: config.limits,
      trustProxy: config.trustProxy,
    );
    return _run(req);
  }

  Future<shelf.Response> _shelfHandler(shelf.Request sr) async {
    final res = await _run(
      Request(sr, limits: config.limits, trustProxy: config.trustProxy),
    );
    return shelf.Response(
      res.statusCode,
      body: res.body,
      headers: {
        for (final e in res.headers.entries)
          e.key: e.value.length == 1 ? e.value.first : e.value,
      },
    );
  }

  // ---- lifecycle ----------------------------------------------------------------

  /// Starts listening. Handles SIGINT/SIGTERM with a graceful shutdown
  /// (in-flight requests may finish for up to `config.shutdownGracePeriod`).
  Future<void> start({
    String? host,
    int? port,
    bool handleSignals = true,
  }) async {
    if (_server != null) throw StateError('The server is already running.');
    final h = host ?? config.effectiveHost;
    final p = port ?? config.port;
    final server = await shelf_io.serve(
      _shelfHandler,
      h,
      p,
      poweredByHeader: null,
    );
    server.autoCompress = false;
    _server = server;
    _stopped = Completer<void>();
    logger.info(
      '${config.name} listening on http://${server.address.host}:${server.port}',
      context: {'environment': config.environment.name},
    );
    if (handleSignals) {
      for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
        try {
          _signals.add(
            sig.watch().listen((_) {
              logger.info('Received ${sig.toString()}, shutting down...');
              unawaited(stop().then((_) => exit(0)));
            }),
          );
        } on SignalException {
          // Signal not supported on this platform.
        }
      }
    }
  }

  /// Completes when the server has stopped.
  Future<void> get done => _stopped?.future ?? Future.value();

  /// Stops accepting connections, drains in-flight requests (then forces
  /// remaining ones closed after the grace period) and runs shutdown hooks.
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    for (final s in _signals) {
      await s.cancel();
    }
    _signals.clear();
    final closing = server
        .close(); // stops accepting, waits for active requests
    try {
      await closing.timeout(config.shutdownGracePeriod);
    } on TimeoutException {
      logger.warning('Grace period elapsed; forcing open connections closed.');
      await server.close(force: true);
    }
    for (final hook in _shutdownHooks.reversed) {
      try {
        await hook();
      } catch (e, st) {
        logger.error('Shutdown hook failed', error: e, stackTrace: st);
      }
    }
    if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
  }
}
