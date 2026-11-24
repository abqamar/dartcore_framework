// Cache facade, cache-aside, namespaces and LRU (no server needed).
//
// Observed output of `dart run example/dartcore_cache_example.dart`:
//
//   get      = {text: hello}
//   remember = 100, 100 (loader ran 1 time)
//   after namespace clear = null
//   other keys untouched  = {text: hello}
//   LRU: a=null c=3

import 'package:dartcore_cache/dartcore_cache.dart';

Future<void> main() async {
  // Static facade (uses an in-memory store by default).
  await Cache.put('greeting', {
    'text': 'hello',
  }, ttl: const Duration(minutes: 1));
  print('get      = ${await Cache.get<Map<String, dynamic>>('greeting')}');

  // Cache-aside: the loader runs once, the second call is served from cache.
  var loads = 0;
  Future<int> expensive() async => ++loads * 100;
  final a = await Cache.remember(
    'stats',
    const Duration(minutes: 1),
    expensive,
  );
  final b = await Cache.remember(
    'stats',
    const Duration(minutes: 1),
    expensive,
  );
  print('remember = $a, $b (loader ran $loads time)');

  // Namespaces prefix keys and can be cleared independently.
  final users = Cache.namespace('users');
  await users.put('1', {'name': 'Alice'});
  await users.clear();
  print('after namespace clear = ${await users.get<Object>('1')}');
  print('other keys untouched  = ${await Cache.get<Object>('greeting')}');

  // An instance with its own bounded store (TTL expiry + LRU eviction).
  final repo = CacheRepository(MemoryCacheStore(maxEntries: 2));
  await repo.put('a', 1);
  await repo.put('b', 2);
  await repo.put('c', 3); // evicts the least recently used key
  print('LRU: a=${await repo.get<int>('a')} c=${await repo.get<int>('c')}');
}
