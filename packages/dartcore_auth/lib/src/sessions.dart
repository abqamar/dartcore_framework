import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dartcore_api/dartcore_api.dart';

class Session {
  Session(this.userId, this.expiresAt, this.data);
  final String userId;
  DateTime expiresAt;
  final Map<String, Object?> data;
}

/// Server-side cookie sessions with an opaque random id. Only the SHA-256 of
/// the id is stored, sessions expire (sliding window) and can be destroyed.
///
/// The default store is process-local memory; supply [store] for shared
/// storage across instances.
class SessionManager {
  SessionManager({
    this.cookieName = 'dartcore_session',
    this.ttl = const Duration(hours: 2),
    this.secureCookie = true,
    Map<String, Session>? store,
  }) : _store = store ?? {};

  final String cookieName;
  final Duration ttl;
  final bool secureCookie;
  final Map<String, Session> _store;
  static final _rng = Random.secure();

  static String _hash(String id) => sha256.convert(utf8.encode(id)).toString();

  /// Creates a session and returns [response] with the session cookie set.
  Response start(
    Response response,
    String userId, {
    Map<String, Object?> data = const {},
  }) {
    final id = base64Url
        .encode(List.generate(32, (_) => _rng.nextInt(256)))
        .replaceAll('=', '');
    _store[_hash(id)] = Session(userId, DateTime.now().add(ttl), {...data});
    return response.cookie(cookieName, id, maxAge: ttl, secure: secureCookie);
  }

  Session? current(Request request) {
    final id = request.cookie(cookieName);
    if (id == null) return null;
    final key = _hash(id);
    final s = _store[key];
    if (s == null) return null;
    if (s.expiresAt.isBefore(DateTime.now())) {
      _store.remove(key);
      return null;
    }
    s.expiresAt = DateTime.now().add(ttl); // sliding expiration
    return s;
  }

  /// Destroys the session and expires the cookie.
  Response destroy(Request request, Response response) {
    final id = request.cookie(cookieName);
    if (id != null) _store.remove(_hash(id));
    return response.clearCookie(cookieName);
  }
}
