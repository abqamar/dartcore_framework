import 'package:dartcore_cache/dartcore_cache.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late CacheRepository cache;
  setUp(() {
    now = DateTime(2025);
    cache = CacheRepository(MemoryCacheStore(maxEntries: 3, clock: () => now));
  });

  test('put/get/delete/has with JSON values', () async {
    await cache.put('users', [
      {'id': 1},
    ]);
    expect(await cache.get<List<dynamic>>('users'), [
      {'id': 1},
    ]);
    expect(await cache.has('users'), isTrue);
    await cache.delete('users');
    expect(await cache.get<List<dynamic>>('users'), isNull);
  });

  test('TTL expiry', () async {
    await cache.put('k', 'v', ttl: const Duration(minutes: 10));
    now = now.add(const Duration(minutes: 9));
    expect(await cache.get<String>('k'), 'v');
    now = now.add(const Duration(minutes: 2));
    expect(await cache.get<String>('k'), isNull);
    await cache.put('gone', 1, ttl: Duration.zero);
    expect(await cache.has('gone'), isFalse);
  });

  test('values are snapshots, not shared references', () async {
    final m = {'a': 1};
    await cache.put('m', m);
    m['a'] = 2;
    expect((await cache.get<Map<String, dynamic>>('m'))!['a'], 1);
  });

  test('LRU eviction keeps recently used keys', () async {
    for (final k in ['a', 'b', 'c']) {
      await cache.put(k, k);
    }
    await cache.get<String>('a'); // touch a
    await cache.put('d', 'd'); // evicts b
    expect(await cache.has('a'), isTrue);
    expect(await cache.has('b'), isFalse);
  });

  test('namespaces isolate keys and clear independently', () async {
    final users = cache.withNamespace('users'),
        posts = cache.withNamespace('posts');
    await users.put('1', 'u');
    await posts.put('1', 'p');
    expect(await users.get<String>('1'), 'u');
    await users.clear();
    expect(await users.has('1'), isFalse);
    expect(await posts.get<String>('1'), 'p');
  });

  test('remember computes once, shares in-flight loads, skips null', () async {
    var calls = 0;
    Future<int> load() async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 42;
    }

    final results = await Future.wait([
      for (var i = 0; i < 5; i++)
        cache.remember('x', const Duration(minutes: 1), load),
    ]);
    expect(results, everyElement(42));
    expect(calls, 1);
    expect(await cache.remember('x', const Duration(minutes: 1), load), 42);
    expect(calls, 1);
    var n = 0;
    Future<int?> nothing() async => n++ == 0 ? null : 7;
    expect(
      await cache.remember<int?>('n', const Duration(minutes: 1), nothing),
      isNull,
    );
    expect(
      await cache.remember<int?>('n', const Duration(minutes: 1), nothing),
      7,
    );
  });

  test('errors are not cached and in-flight entry is released', () async {
    var n = 0;
    Future<int> flaky() async => ++n == 1 ? throw StateError('x') : 1;
    await expectLater(
      cache.remember('f', const Duration(minutes: 1), flaky),
      throwsStateError,
    );
    expect(await cache.remember('f', const Duration(minutes: 1), flaky), 1);
  });

  test('non-JSON values and empty keys are rejected', () async {
    await expectLater(cache.put('k', Object()), throwsArgumentError);
    await expectLater(cache.get<String>(''), throwsArgumentError);
  });

  test(
    'DateTime, BigInt, Duration and toJson() objects are cached as JSON',
    () async {
      await cache.put('rich', {
        'at': DateTime.utc(2025, 1, 2, 3),
        'big': BigInt.from(10),
        'for': const Duration(seconds: 2),
        'obj': _Obj(),
      });
      expect(await cache.get<Map<String, dynamic>>('rich'), {
        'at': '2025-01-02T03:00:00.000Z',
        'big': '10',
        'for': 2000,
        'obj': {'x': 1},
      });
    },
  );

  test('static facade', () async {
    Cache.reset();
    await Cache.put('users', [1, 2], ttl: const Duration(minutes: 10));
    expect(await Cache.get<List<dynamic>>('users'), [1, 2]);
    await Cache.delete('users');
    expect(await Cache.has('users'), isFalse);
  });
}

class _Obj {
  Map<String, Object?> toJson() => {'x': 1};
}
