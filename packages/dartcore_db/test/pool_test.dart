import 'dart:async';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:test/test.dart';

class _Res {
  _Res(this.id);
  final int id;
  bool dead = false;
}

void main() {
  late int created;
  late List<_Res> destroyed;

  ConnectionPool<_Res> make({
    int max = 2,
    Duration? idle,
    Duration? acquire,
    bool validate = false,
  }) {
    created = 0;
    destroyed = [];
    return ConnectionPool<_Res>(
      create: () async => _Res(++created),
      destroy: (r) async => destroyed.add(r),
      validate: validate ? (r) async => !r.dead : null,
      validateAfterIdle: Duration.zero,
      maxSize: max,
      idleTimeout: idle ?? const Duration(minutes: 5),
      acquireTimeout: acquire ?? const Duration(seconds: 5),
    );
  }

  test('reuses released resources and caps size', () async {
    final p = make();
    final a = await p.acquire();
    p.release(a);
    final b = await p.acquire();
    expect(b, same(a));
    expect(created, 1);
    await p.close();
  });

  test('waiters are served FIFO when pool is exhausted', () async {
    final p = make(max: 1);
    final a = await p.acquire();
    final order = <int>[];
    final f1 = p.acquire().then((r) {
      order.add(1);
      return r;
    });
    final f2 = p.acquire().then((r) {
      order.add(2);
      return r;
    });
    expect(p.stats.waiting, 2);
    p.release(a);
    final r1 = await f1;
    p.release(r1);
    await f2;
    expect(order, [1, 2]);
    expect(created, 1);
    await p.close();
  });

  test('acquire times out with ConnectionException', () async {
    final p = make(max: 1, acquire: const Duration(milliseconds: 50));
    await p.acquire();
    await expectLater(p.acquire(), throwsA(isA<ConnectionException>()));
    expect(p.stats.waiting, 0);
    await p.close();
  });

  test('discarded resource frees capacity for waiters', () async {
    final p = make(max: 1);
    final a = await p.acquire();
    final waiting = p.acquire();
    p.release(a, discard: true);
    final b = await waiting;
    expect(b.id, 2);
    expect(destroyed, [a]);
    await p.close();
  });

  test('unhealthy idle resources are replaced (reconnection)', () async {
    final p = make(validate: true);
    final a = await p.acquire();
    p.release(a);
    a.dead = true;
    final b = await p.acquire();
    expect(b.id, 2);
    expect(destroyed, contains(a));
    await p.close();
  });

  test('idle resources are evicted after idleTimeout', () async {
    final p = make(idle: const Duration(milliseconds: 100));
    p.release(await p.acquire());
    expect(p.stats.idle, 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(p.stats.size, 0);
    expect(destroyed, hasLength(1));
    await p.close();
  });

  test('create failures do not leak capacity', () async {
    var fail = true;
    final p = ConnectionPool<_Res>(
      create: () async => fail ? throw ConnectionException('down') : _Res(1),
      destroy: (_) async {},
      maxSize: 1,
    );
    await expectLater(p.acquire(), throwsA(isA<ConnectionException>()));
    fail = false;
    expect(await p.acquire(), isA<_Res>());
    await p.close();
  });

  test('close fails pending waiters and destroys idle', () async {
    final p = make(max: 1);
    final a = await p.acquire();
    final w = p.acquire();
    final expectation = expectLater(w, throwsA(isA<ConnectionException>()));
    await p.close();
    await expectation;
    p.release(a);
    expect(destroyed, contains(a));
  });
}
