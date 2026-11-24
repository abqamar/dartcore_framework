# dartcore_cache

Cache abstraction for DartCore with an in-memory store (TTL, LRU, namespaces) and cache-aside with in-flight de-duplication.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub add dartcore_cache
```

## Usage

```dart
import 'package:dartcore_cache/dartcore_cache.dart';

Future<void> main() async {
  await Cache.put('users', users, ttl: const Duration(minutes: 10));   // value must be JSON-encodable
  final cached = await Cache.get<List<dynamic>>('users');
  await Cache.delete('users');

  // Cache-aside: concurrent callers share one loader run; null and errors are not cached.
  final stats = await Cache.remember('stats', const Duration(minutes: 1), () => computeStats());

  final ns = Cache.namespace('users');          // keys are prefixed "users:"
  await ns.put('1', row);
  await ns.clear();                             // clears only that namespace

  final repo = CacheRepository(MemoryCacheStore(maxEntries: 10000));   // or Cache.use(...) to swap the default
}
```

Values are stored as JSON strings, so you always get snapshots and every backend behaves the same.
To add another backend, implement `CacheStore` (`read`, `write`, `remove`, `removeByPrefix`).

A runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_cache/example/dartcore_cache_example.dart) is included.

## Status and limits

Pre-1.0: the API may change. Only the in-memory store exists: **there is no Redis adapter yet**, and the memory store
is per process and lost on restart. Do not cache secrets or personal data by default.
See [caching and logging](https://github.com/abqamar/dartcore_framework/blob/main/docs/cache-logging.md).
