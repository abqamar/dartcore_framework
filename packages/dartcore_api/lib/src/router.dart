import 'middleware/middleware.dart';

/// A registered route.
class Route {
  Route._(
    this.method,
    this.path,
    this.handler,
    this.middleware,
    this.name,
    this.timeout,
    this._regex,
    this.paramNames,
    this.isStatic,
  );

  factory Route.build(
    String method,
    String path,
    Handler handler, {
    List<Middleware> middleware = const [],
    String? name,
    Duration? timeout,
  }) {
    final normalized = normalizePath(path);
    final names = <String>[];
    final isStatic = !normalized.contains(':') && !normalized.contains('*');
    final buf = StringBuffer('^');
    for (final seg in normalized.split('/').skip(1)) {
      buf.write('/');
      if (seg.startsWith(':')) {
        final n = seg.substring(1);
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n)) {
          throw ArgumentError('Invalid route parameter "$seg" in "$path".');
        }
        names.add(n);
        buf.write('([^/]+)');
      } else if (seg == '*') {
        names.add('*');
        buf.write('(.*)');
      } else {
        buf.write(RegExp.escape(seg));
      }
    }
    if (normalized == '/') {
      buf.clear();
      buf.write('^/');
    }
    buf.write(r'$');
    return Route._(
      method.toUpperCase(),
      normalized,
      handler,
      middleware,
      name,
      timeout,
      RegExp(buf.toString()),
      names,
      isStatic,
    );
  }

  final String method;
  final String path;
  final Handler handler;
  final List<Middleware> middleware;
  final String? name;
  final Duration? timeout;
  final RegExp _regex;
  final List<String> paramNames;
  final bool isStatic;

  Map<String, String>? match(String requestPath) {
    final m = _regex.firstMatch(requestPath);
    if (m == null) return null;
    final out = <String, String>{};
    for (var i = 0; i < paramNames.length; i++) {
      final raw = m.group(i + 1)!;
      try {
        out[paramNames[i]] = Uri.decodeComponent(raw);
      } on ArgumentError {
        return null; // malformed percent-encoding never matches
      }
    }
    return out;
  }

  /// Builds a URL for this route from [params] (values are percent-encoded).
  String urlFor(Map<String, Object> params) {
    final segs = path.split('/').skip(1).map((s) {
      if (s.startsWith(':') || s == '*') {
        final key = s == '*' ? '*' : s.substring(1);
        final v =
            params[key] ?? (throw ArgumentError('Missing parameter "$key".'));
        return Uri.encodeComponent(v.toString());
      }
      return s;
    });
    return '/${segs.join('/')}';
  }

  static String normalizePath(String p) {
    var path = p.startsWith('/') ? p : '/$p';
    path = path.replaceAll(RegExp(r'/{2,}'), '/');
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }
}

class RouteMatch {
  RouteMatch(this.route, this.params);
  final Route route;
  final Map<String, String> params;
}

/// Method-indexed router. Static paths use an O(1) map; parameterized routes
/// are tried in registration order.
class Router {
  final Map<String, Map<String, Route>> _static = {};
  final Map<String, List<Route>> _dynamic = {};
  final Map<String, Route> _named = {};
  final List<Route> routes = [];

  void add(Route r) {
    if (r.isStatic && _static[r.method]?[r.path] != null) {
      throw StateError('Duplicate route ${r.method} ${r.path}.');
    }
    if (r.name != null) {
      if (_named.containsKey(r.name)) {
        throw StateError('Duplicate route name "${r.name}".');
      }
      _named[r.name!] = r;
    }
    if (r.isStatic) {
      (_static[r.method] ??= {})[r.path] = r;
    } else {
      (_dynamic[r.method] ??= []).add(r);
    }
    routes.add(r);
  }

  Route? named(String name) => _named[name];

  RouteMatch? match(String method, String rawPath) {
    final path = Route.normalizePath(rawPath);
    final s = _static[method]?[path];
    if (s != null) return RouteMatch(s, const {});
    for (final r in _dynamic[method] ?? const <Route>[]) {
      final p = r.match(path);
      if (p != null) return RouteMatch(r, p);
    }
    return null;
  }

  /// Methods that would match [rawPath] (for 405 / OPTIONS).
  Set<String> allowedMethods(String rawPath) {
    final path = Route.normalizePath(rawPath);
    return {
      for (final m in {..._static.keys, ..._dynamic.keys})
        if (_static[m]?[path] != null ||
            (_dynamic[m] ?? const <Route>[]).any((r) => r.match(path) != null))
          m,
    };
  }
}
