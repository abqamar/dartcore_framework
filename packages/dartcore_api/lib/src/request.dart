import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart' as shelf;

/// Limits applied while reading request bodies.
class BodyLimits {
  const BodyLimits({
    this.maxBodyBytes = 1024 * 1024,
    this.maxUploadBytes = 10 * 1024 * 1024,
  });

  /// JSON / form / text bodies (default 1 MiB).
  final int maxBodyBytes;

  /// multipart bodies (default 10 MiB total, held in memory).
  final int maxUploadBytes;
}

class UploadedFile {
  UploadedFile({
    required this.field,
    required String filename,
    required this.contentType,
    required this.bytes,
  }) : filename = _safeName(filename);

  final String field;

  /// Client-supplied name reduced to a bare file name (no directories). Never
  /// use it as a trusted storage path without further validation.
  final String filename;
  final String contentType;
  final Uint8List bytes;
  int get size => bytes.length;

  String get extension {
    final i = filename.lastIndexOf('.');
    return i < 0 ? '' : filename.substring(i + 1).toLowerCase();
  }

  static String _safeName(String name) {
    final base = name
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f]'), '');
    return base == '..' || base == '.' ? '' : base;
  }
}

/// An incoming HTTP request.
class Request {
  Request(
    this._shelf, {
    Map<String, String> params = const {},
    this.limits = const BodyLimits(),
    this.trustProxy = false,
  }) : _params = params;

  final shelf.Request _shelf;
  final Map<String, String> _params;
  final BodyLimits limits;
  final bool trustProxy;

  /// Per-request storage for middleware (`user`, `request_id`, ...).
  final Map<String, Object?> attributes = {};

  Request withParams(Map<String, String> params) =>
      Request(_shelf, params: params, limits: limits, trustProxy: trustProxy)
        ..attributes.addAll(attributes)
        .._cache = _cache;

  /// Escape hatch to the underlying Shelf request.
  shelf.Request toShelf() => _shelf;

  String get method => _shelf.method.toUpperCase();
  Uri get uri => _shelf.requestedUri;
  String get path => uri.path;

  /// Route parameter (`/users/:id` -> `param('id')`), or `null`.
  String? param(String name) => _params[name];
  Map<String, String> get params => Map.unmodifiable(_params);

  String? query(String name, [String? defaultValue]) =>
      uri.queryParameters[name] ?? defaultValue;
  Map<String, String> get queries => uri.queryParameters;
  List<String> queryAll(String name) =>
      uri.queryParametersAll[name] ?? const [];

  /// Case-insensitive header lookup.
  String? header(String name) => _shelf.headers[name.toLowerCase()];
  Map<String, String> get headers => _shelf.headers;

  String? get contentType =>
      header('content-type')?.split(';').first.trim().toLowerCase();

  String? cookie(String name) {
    final raw = header('cookie');
    if (raw == null) return null;
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i > 0 && part.substring(0, i).trim() == name) {
        try {
          return Uri.decodeComponent(part.substring(i + 1).trim());
        } catch (_) {
          return part.substring(i + 1).trim();
        }
      }
    }
    return null;
  }

  /// Client IP. `X-Forwarded-For` is honoured only when the app was configured
  /// with `trustProxy: true`, otherwise it is trivially spoofable.
  String get ip {
    if (trustProxy) {
      final fwd = header('x-forwarded-for');
      if (fwd != null && fwd.trim().isNotEmpty) {
        return fwd.split(',').first.trim();
      }
    }
    final info = _shelf.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return 'unknown';
  }

  // ---- body ------------------------------------------------------------------
  //
  // The body stream can only be read once, so it is buffered on first use and
  // every accessor below shares that buffer.

  _BodyCache _cache = _BodyCache();

  Future<Uint8List> bytes() => _cache.bytes ??= _readBytes(limits.maxBodyBytes);

  Future<Uint8List> _readBytes(int max) async {
    final declared = int.tryParse(header('content-length') ?? '');
    if (declared != null && declared > max) {
      throw HttpStatusException(
        413,
        'Request body too large (limit $max bytes).',
      );
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in _shelf.read()) {
      out.add(chunk);
      if (out.length > max) {
        throw HttpStatusException(
          413,
          'Request body too large (limit $max bytes).',
        );
      }
    }
    return out.takeBytes();
  }

  Future<String> text() async {
    try {
      return utf8.decode(await bytes());
    } on FormatException {
      throw HttpStatusException(400, 'Request body is not valid UTF-8.');
    }
  }

  /// Parses a JSON *object* body. Throws a 400 for malformed JSON or a
  /// non-object body (use [jsonAny] for arrays).
  Future<Map<String, dynamic>> json() async {
    final v = await jsonAny();
    if (v is Map<String, dynamic>) return v;
    throw HttpStatusException(400, 'Expected a JSON object body.');
  }

  Future<Object?> jsonAny() async {
    final raw = await text();
    if (raw.trim().isEmpty) {
      throw HttpStatusException(400, 'Request body is empty; expected JSON.');
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw HttpStatusException(400, 'Request body is not valid JSON.');
    }
  }

  /// `application/x-www-form-urlencoded` fields (last value wins).
  Future<Map<String, String>> form() async {
    final raw = await text();
    try {
      return Uri.splitQueryString(raw);
    } on FormatException {
      throw HttpStatusException(400, 'Malformed form body.');
    }
  }

  /// Parsed body by content type: JSON object, form, or multipart fields.
  /// Empty map for requests without a body.
  Future<Map<String, dynamic>> body() async {
    switch (contentType) {
      case 'application/json':
        return json();
      case 'application/x-www-form-urlencoded':
        return {...await form()};
      case 'multipart/form-data':
        return {...(await multipart()).fields};
      case null:
        return {};
      default:
        throw HttpStatusException(
          415,
          'Unsupported content type "$contentType".',
        );
    }
  }

  Future<({Map<String, String> fields, List<UploadedFile> files})>
  multipart() => _cache.multipart ??= _readMultipart();

  Future<List<UploadedFile>> files() async => (await multipart()).files;

  Future<({Map<String, String> fields, List<UploadedFile> files})>
  _readMultipart() async {
    final ct = header('content-type') ?? '';
    final boundary = RegExp(
      r'boundary="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(ct)?.group(1);
    if (!ct.toLowerCase().startsWith('multipart/') || boundary == null) {
      throw HttpStatusException(400, 'Expected a multipart/form-data body.');
    }
    final data = await _readBytes(limits.maxUploadBytes);
    final fields = <String, String>{};
    final files = <UploadedFile>[];
    try {
      await for (final part in MimeMultipartTransformer(
        boundary,
      ).bind(Stream.value(data))) {
        final disp = part.headers['content-disposition'] ?? '';
        final name = RegExp(r'name="([^"]*)"').firstMatch(disp)?.group(1);
        final filename = RegExp(
          r'filename="([^"]*)"',
        ).firstMatch(disp)?.group(1);
        final body = BytesBuilder(copy: false);
        await for (final c in part) {
          body.add(c);
        }
        if (name == null) continue;
        if (filename != null) {
          files.add(
            UploadedFile(
              field: name,
              filename: filename,
              contentType:
                  part.headers['content-type'] ?? 'application/octet-stream',
              bytes: body.takeBytes(),
            ),
          );
        } else {
          fields[name] = utf8.decode(body.takeBytes(), allowMalformed: true);
        }
      }
    } on MimeMultipartException {
      throw HttpStatusException(400, 'Malformed multipart body.');
    }
    return (fields: fields, files: files);
  }
}

class _BodyCache {
  Future<Uint8List>? bytes;
  Future<({Map<String, String> fields, List<UploadedFile> files})>? multipart;
}
