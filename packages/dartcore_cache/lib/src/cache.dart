import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartcore_core/dartcore_core.dart';

/// Backend contract. Values are stored as JSON strings, so cached values are
/// snapshots (mutating the object you put in never changes the cache) and any
/// store (memory, Redis, ...) behaves the same.
abstract interface class CacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value, Duration? ttl);
  Future<void> remove(String key);

  /// Removes every key starting with [prefix] (an empty prefix clears all).
  Future<void> removeByPrefix(String prefix);
}

/// Process-local store with TTL expiry and LRU eviction at [maxEntries].
class MemoryCacheStore implements CacheStore {
  MemoryCacheStore({this.maxEntries = 10000, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final int maxEntries;
  final DateTime Function() _now;
  final LinkedHashMap<String, _Entry> _data = LinkedHashMap();

  int get length => _data.length;

  @override
  Future<String?> read(String key) async {
    final e = _data.remove(key);
    if (e == null) return null;
    if (e.expiresAt != null && !e.expiresAt!.isAfter(_now())) return null;
    _data[key] = e; // move to most-recently-used
    return e.value;
  }

  @override
  Future<void> write(String key, String value, Duration? ttl) async {
    _data.remove(key);
    _data[key] = _Entry(value, ttl == null ? null : _now().add(ttl));
    if (_data.length > maxEntries) {
      _purgeExpired();
      while (_data.length > maxEntries) {
        _data.remove(_data.keys.first);
      }
    }
  }

  void _purgeExpired() {
    final now = _now();
    _data.removeWhere(
      (_, e) => e.expiresAt != null && !e.expiresAt!.isAfter(now),
    );
  }

  @override
  Future<void> remove(String key) async => _data.remove(key);

  @override
  Future<void> removeByPrefix(String prefix) async =>
      _data.removeWhere((k, _) => k.startsWith(prefix));
}

class _Entry {
  _Entry(this.value, this.expiresAt);
  final String value;
  final DateTime? expiresAt;
}

/// Encodes values JSON cannot represent natively: `DateTime` (UTC ISO-8601),
/// `BigInt`, `Duration` (milliseconds), iterables and objects with `toJson()`.
/// Cached values come back as their JSON form (a `DateTime` is read back as a string).
Object? _toEncodable(Object? o) {
  if (o is DateTime) {
    return o.toUtc().toIso8601String();
  }
  if (o is BigInt) {
    return o.toString();
  }
  if (o is Duration) {
    return o.inMilliseconds;
  }
  if (o is Iterable) {
    return o.toList();
  }
  return (o as dynamic).toJson();
}

/// A cache (optionally scoped to a [namespace]).
///
/// Do not cache secrets or personal data by default; cache derived,
/// non-sensitive results and choose short TTLs.
class CacheRepository {
  CacheRepository(
    this.store, {
    this.namespace = '',
    Map<String, Future<Object?>>? inFlight,
  }) : _inFlight = inFlight ?? {};

  final CacheStore store;
  final String namespace;
  final Map<String, Future<Object?>> _inFlight;

  String _k(String key) {
    if (key.isEmpty) throw ArgumentError('Cache key must not be empty.');
    return namespace.isEmpty ? key : '$namespace:$key';
  }

  /// A view whose keys are prefixed with `name:`; [clear] only affects it.
  CacheRepository withNamespace(String name) => CacheRepository(
    store,
    namespace: namespace.isEmpty ? name : '$namespace:$name',
    inFlight: _inFlight,
  );

  Future<void> put(String key, Object? value, {Duration? ttl}) async {
    if (ttl != null && ttl <= Duration.zero) return;
    final String encoded;
    try {
      encoded = jsonEncode(value, toEncodable: _toEncodable);
    } on JsonUnsupportedObjectError catch (e) {
      throw ArgumentError('Only JSON-encodable values can be cached: $e');
    }
    await store.write(_k(key), encoded, ttl);
  }

  Future<T?> get<T>(String key) async {
    final raw = await store.read(_k(key));
    if (raw == null) return null;
    final v = jsonDecode(raw);
    return v is T ? v : null;
  }

  Future<bool> has(String key) async => (await store.read(_k(key))) != null;

  Future<void> delete(String key) => store.remove(_k(key));

  /// Clears this namespace (or everything when there is none).
  Future<void> clear() =>
      store.removeByPrefix(namespace.isEmpty ? '' : '$namespace:');

  /// Cache-aside: returns the cached value or computes, stores and returns it.
  /// Concurrent callers for the same key share one [loader] run (no stampede).
  /// A `null` result is not cached.
  Future<T> remember<T>(
    String key,
    Duration ttl,
    Future<T> Function() loader,
  ) async {
    final hit = await get<T>(key);
    if (hit != null) return hit;
    final k = _k(key);
    final running = _inFlight[k];
    if (running != null) return (await running) as T;
    final future = (() async {
      final value = await loader();
      if (value != null) await put(key, value, ttl: ttl);
      return value;
    })();
    _inFlight[k] = future;
    try {
      return await future;
    } finally {
      unawaited(_inFlight.remove(k));
    }
  }
}

/// Static facade over a managed default [CacheRepository] (in-memory unless
/// replaced with [Cache.use]).
abstract final class Cache {
  static CacheRepository _instance = CacheRepository(MemoryCacheStore());

  static CacheRepository get instance => _instance;
  static void use(CacheRepository repo) => _instance = repo;
  static void reset() => _instance = CacheRepository(MemoryCacheStore());

  static Future<void> put(String key, Object? value, {Duration? ttl}) =>
      _instance.put(key, value, ttl: ttl);
  static Future<T?> get<T>(String key) => _instance.get<T>(key);
  static Future<bool> has(String key) => _instance.has(key);
  static Future<void> delete(String key) => _instance.delete(key);
  static Future<void> clear() => _instance.clear();
  static Future<T> remember<T>(
    String key,
    Duration ttl,
    Future<T> Function() loader,
  ) => _instance.remember<T>(key, ttl, loader);
  static CacheRepository namespace(String name) =>
      _instance.withNamespace(name);
}

/// Thrown when a cache backend is misconfigured.
class CacheConfigurationException extends ConfigurationException {
  CacheConfigurationException(super.message);
}
