import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'json.dart';

/// An HTTP response. (Named `Response` for ergonomics; it is DartCore's own
/// type and is independent of `package:shelf`'s class of the same name.)
class Response {
  Response._(this.statusCode, this._headers, this.body);

  final int statusCode;
  final Map<String, List<String>> _headers;

  /// A `Uint8List`, a `Stream<List<int>>`, or null.
  final Object? body;

  Map<String, List<String>> get headers => _headers;

  String? header(String name) => _headers[name.toLowerCase()]?.first;

  /// Creates a response from raw parts.
  factory Response(
    int statusCode, {
    Object? body,
    Map<String, Object>? headers,
  }) => Response._(statusCode, _normalize(headers), _coerce(body));

  // ---- JSON ---------------------------------------------------------------

  /// JSON response with [data] encoded as-is.
  factory Response.json(
    Object? data, {
    int status = 200,
    Map<String, Object>? headers,
  }) {
    final h = _normalize(headers);
    h.putIfAbsent('content-type', () => ['application/json; charset=utf-8']);
    return Response._(
      status,
      h,
      Uint8List.fromList(utf8.encode(encodeJson(data))),
    );
  }

  /// 200 with [data] encoded as-is: `Response.ok(users)`.
  factory Response.ok([Object? data, Map<String, Object>? headers]) =>
      data == null
      ? Response._(200, _normalize(headers), null)
      : Response.json(data, headers: headers);

  factory Response.created([Object? data, Map<String, Object>? headers]) =>
      Response.json(data, status: 201, headers: headers);

  factory Response.noContent() => Response._(204, {}, null);

  /// Standard envelope: `{success: true, message, data, meta}`.
  factory Response.success(
    Object? data, {
    String message = 'Success',
    Object? meta,
    int status = 200,
    Map<String, Object>? headers,
  }) => Response.json(
    {'success': true, 'message': message, 'data': data, 'meta': meta},
    status: status,
    headers: headers,
  );

  /// Standard error envelope: `{success: false, message, errors?}`.
  /// [message] may be a `String` (wrapped in the envelope) or a `Map`, which is
  /// sent as-is.
  factory Response.error(
    Object? message, {
    int status = 500,
    Map<String, Object?>? errors,
  }) {
    if (message is Map) return Response.json(message, status: status);
    return Response.json({
      'success': false,
      'message': message?.toString() ?? _reason(status),
      'errors': ?errors,
    }, status: status);
  }

  factory Response.badRequest([Object? message = 'Bad request']) =>
      Response.error(message, status: 400);
  factory Response.unauthorized([Object? message = 'Unauthenticated']) =>
      Response.error(message, status: 401);
  factory Response.forbidden([Object? message = 'Forbidden']) =>
      Response.error(message, status: 403);
  factory Response.notFound([Object? message = 'Not found']) =>
      Response.error(message, status: 404);
  factory Response.serverError([Object? message = 'Internal server error']) =>
      Response.error(message, status: 500);

  /// 422 with `errors: {field: [messages]}`.
  factory Response.validationError(
    Map<String, List<String>> errors, {
    String message = 'Validation failed',
  }) => Response.error(message, status: 422, errors: errors);

  // ---- other bodies ----------------------------------------------------------

  factory Response.text(
    String text, {
    int status = 200,
    Map<String, Object>? headers,
  }) => _typed(status, text, 'text/plain; charset=utf-8', headers);

  factory Response.html(
    String html, {
    int status = 200,
    Map<String, Object>? headers,
  }) => _typed(status, html, 'text/html; charset=utf-8', headers);

  /// Redirect. [location] must be a path or absolute URL you trust; never pass
  /// unvalidated user input (open-redirect risk).
  factory Response.redirect(String location, {int status = 302}) =>
      Response._(status, {
        'location': [location],
      }, null);

  /// Streams [stream] to the client without buffering it.
  factory Response.stream(
    Stream<List<int>> stream, {
    int status = 200,
    String contentType = 'application/octet-stream',
    Map<String, Object>? headers,
  }) => Response._(status, {
    ..._normalize(headers),
    'content-type': [contentType],
  }, stream);

  /// Sends bytes as a file download.
  factory Response.download(
    List<int> bytes,
    String filename, {
    String contentType = 'application/octet-stream',
  }) {
    final safe = filename.replaceAll(RegExp(r'[\r\n"\\/]'), '_');
    return Response._(200, {
      'content-type': [contentType],
      'content-disposition': [
        'attachment; filename="$safe"; filename*=UTF-8\'\'${Uri.encodeComponent(filename)}',
      ],
    }, Uint8List.fromList(bytes));
  }

  /// Streams a file from disk as a download.
  factory Response.file(
    String path, {
    String? downloadName,
    String? contentType,
  }) {
    final file = File(path);
    final name = downloadName ?? file.uri.pathSegments.last;
    final safe = name.replaceAll(RegExp(r'[\r\n"\\/]'), '_');
    return Response._(200, {
      'content-type': [contentType ?? 'application/octet-stream'],
      'content-disposition': ['attachment; filename="$safe"'],
    }, file.openRead());
  }

  // ---- modifiers -----------------------------------------------------------

  /// Returns a copy with [name] set to [value].
  Response withHeader(String name, String value) {
    final h = {for (final e in _headers.entries) e.key: List.of(e.value)};
    h[name.toLowerCase()] = [value];
    return Response._(statusCode, h, body);
  }

  Response withStatus(int status) => Response._(status, _headers, body);

  /// Adds a `Set-Cookie` header. Defaults are secure: `HttpOnly`,
  /// `SameSite=Lax`, `Secure`. Pass `secure: false` only for local HTTP dev.
  Response cookie(
    String name,
    String value, {
    Duration? maxAge,
    String path = '/',
    String? domain,
    bool httpOnly = true,
    bool secure = true,
    String sameSite = 'Lax',
  }) {
    if (RegExp(r'[\s;,"\\\x00-\x1f]').hasMatch(name) ||
        RegExp(r'[;\r\n]').hasMatch(value)) {
      throw ArgumentError('Invalid cookie name or value.');
    }
    final parts = [
      '$name=${Uri.encodeComponent(value)}',
      'Path=$path',
      if (domain != null) 'Domain=$domain',
      if (maxAge != null) 'Max-Age=${maxAge.inSeconds}',
      if (httpOnly) 'HttpOnly',
      if (secure) 'Secure',
      'SameSite=$sameSite',
    ];
    final h = {for (final e in _headers.entries) e.key: List.of(e.value)};
    (h['set-cookie'] ??= []).add(parts.join('; '));
    return Response._(statusCode, h, body);
  }

  /// Expires a cookie.
  Response clearCookie(String name, {String path = '/'}) =>
      cookie(name, '', maxAge: Duration.zero, path: path);

  // ---- internals -----------------------------------------------------------

  static Response _typed(
    int status,
    String text,
    String type,
    Map<String, Object>? headers,
  ) {
    final h = _normalize(headers);
    h.putIfAbsent('content-type', () => [type]);
    return Response._(status, h, Uint8List.fromList(utf8.encode(text)));
  }

  static Map<String, List<String>> _normalize(Map<String, Object>? headers) => {
    if (headers != null)
      for (final e in headers.entries)
        e.key.toLowerCase(): e.value is Iterable
            ? [for (final v in e.value as Iterable) v.toString()]
            : [e.value.toString()],
  };

  static Object? _coerce(Object? body) {
    if (body == null) return null;
    if (body is Uint8List) return body;
    if (body is String) return Uint8List.fromList(utf8.encode(body));
    if (body is List<int>) return Uint8List.fromList(body);
    if (body is Stream<List<int>>) return body;
    throw ArgumentError('Unsupported body type ${body.runtimeType}.');
  }

  static String _reason(int status) => switch (status) {
    400 => 'Bad request',
    401 => 'Unauthenticated',
    403 => 'Forbidden',
    404 => 'Not found',
    _ => 'Error',
  };

  @override
  String toString() => 'Response($statusCode)';
}

/// Helpers for reading a [Response] body (mainly for tests and middleware).
extension ResponseBody on Response {
  Future<Uint8List> readBytes() async {
    final b = body;
    if (b == null) return Uint8List(0);
    if (b is Uint8List) return b;
    final out = BytesBuilder(copy: false);
    await for (final chunk in b as Stream<List<int>>) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  Future<String> readText() async => utf8.decode(await readBytes());
  Future<Object?> readJson() async => jsonDecode(await readText());
}
