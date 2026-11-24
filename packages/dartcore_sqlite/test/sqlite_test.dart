import 'dart:io';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

void main() {
  late DatabaseManager manager;
  late Database db;

  setUpAll(registerSqlite);

  setUp(() async {
    manager = DatabaseManager();
    db = await manager.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
    await db.statement(
      'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT UNIQUE, active INTEGER DEFAULT 1, balance REAL DEFAULT 0, created_at TEXT)',
    );
    await db.statement(
      'CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, title TEXT)',
    );
  });

  tearDown(() => manager.disconnect());

  test('insert returns stored row; CRUD round-trip', () async {
    final row = await db.table('users').insert({
      'name': 'John',
      'email': 'j@x.io',
      'active': true,
    });
    expect(row['id'], 1);
    expect(row['active'], 1);
    expect(await db.table('users').find(1), isNotNull);
    expect(await db.table('users').where('id', 1).update({'name': 'Jon'}), 1);
    expect((await db.table('users').find(1))!['name'], 'Jon');
    expect(await db.table('users').where('id', 1).delete(), 1);
    expect(await db.table('users').find(1), isNull);
  });

  test('insertMany, count, exists, aggregates, first', () async {
    await db.table('users').insertMany([
      {'name': 'A', 'email': 'a@x', 'balance': 10},
      {'name': 'B', 'email': 'b@x', 'balance': 20.5},
      {'name': 'C', 'email': 'c@x', 'balance': 30},
    ]);
    expect(await db.table('users').count(), 3);
    expect(await db.table('users').where('name', 'B').exists(), isTrue);
    expect(await db.table('users').where('name', 'Z').exists(), isFalse);
    expect(await db.table('users').sum('balance'), 60.5);
    expect(await db.table('users').max('balance'), 30);
    expect(await db.table('users').min('balance'), 10);
    expect((await db.table('users').avg('balance'))!, closeTo(20.1666, 0.01));
    expect(
      (await db
          .table('users')
          .orderBy('name', descending: true)
          .first())!['name'],
      'C',
    );
  });

  test('where variants against a real engine', () async {
    await db.table('users').insertMany([
      {'name': 'Ann', 'email': 'a@x', 'balance': 1},
      {'name': 'Bob', 'email': 'b@x', 'balance': 2},
      {'name': 'Cat', 'email': null, 'balance': 3},
    ]);
    expect(await db.table('users').whereIn('name', ['Ann', 'Cat']).count(), 2);
    expect(await db.table('users').whereNotIn('name', ['Ann']).count(), 2);
    expect(await db.table('users').whereNull('email').count(), 1);
    expect(await db.table('users').whereNotNull('email').count(), 2);
    expect(await db.table('users').whereBetween('balance', 2, 3).count(), 2);
    expect(await db.table('users').whereLike('name', 'B%').count(), 1);
    expect(await db.table('users').whereIn('name', []).count(), 0);
    expect(
      await db
          .table('users')
          .whereGroup((q) => q.where('name', 'Ann').orWhere('name', 'Bob'))
          .count(),
      2,
    );
    expect(await db.table('users').whereRaw('balance > ?', [1]).count(), 2);
  });

  test('injection attempt is stored literally, table survives', () async {
    const evil = "x'); DROP TABLE users; --";
    await db.table('users').insert({'name': evil, 'email': 'e@x'});
    expect((await db.table('users').first())!['name'], evil);
    expect(await db.table('users').where('name', evil).count(), 1);
  });

  test('joins', () async {
    final u = await db.table('users').insert({'name': 'A', 'email': 'a@x'});
    await db.table('posts').insertMany([
      {'user_id': u['id'], 'title': 'one'},
      {'user_id': u['id'], 'title': 'two'},
    ]);
    final rows = await db
        .table('users')
        .select(['users.name', 'posts.title'])
        .join('posts', 'posts.user_id', '=', 'users.id')
        .orderBy('posts.title')
        .get();
    expect(rows.map((r) => r['title']), ['one', 'two']);
    final left = await db
        .table('users')
        .leftJoin('posts', 'posts.user_id', '=', 'users.id')
        .count();
    expect(left, 2);
  });

  test('pagination', () async {
    await db.table('users').insertMany([
      for (var i = 1; i <= 45; i++) {'name': 'u$i', 'email': 'u$i@x'},
    ]);
    final p2 = await db
        .table('users')
        .orderBy('id')
        .paginate(page: 2, limit: 20);
    expect(p2.total, 45);
    expect(p2.lastPage, 3);
    expect(p2.data.first['name'], 'u21');
    expect(p2.hasNextPage && p2.hasPreviousPage, isTrue);
    final p3 = await db
        .table('users')
        .orderBy('id')
        .paginate(page: 3, limit: 20);
    expect(p3.data, hasLength(5));
    expect(p3.hasNextPage, isFalse);
  });

  test('increment/decrement', () async {
    await db.table('users').insertMany([
      {'name': 'A', 'email': 'a@x', 'balance': 500},
      {'name': 'B', 'email': 'b@x', 'balance': 0},
    ]);
    await db.table('users').where('name', 'A').decrement('balance', 100);
    await db.table('users').where('name', 'B').increment('balance', 100);
    expect(
      (await db.table('users').where('name', 'A').first())!['balance'],
      400,
    );
    expect(
      (await db.table('users').where('name', 'B').first())!['balance'],
      100,
    );
  });

  test('data types: bool, DateTime, null, blob', () async {
    final t = DateTime.utc(2025, 1, 2, 3, 4, 5);
    final row = await db.table('users').insert({
      'name': 'T',
      'active': false,
      'created_at': t,
    });
    expect(row['active'], 0);
    expect(DateTime.parse(row['created_at'] as String), t);
  });

  group('transactions', () {
    test('commit on success', () async {
      await db.table('users').insertMany([
        {'name': 'A', 'email': 'a@x', 'balance': 500},
        {'name': 'B', 'email': 'b@x', 'balance': 0},
      ]);
      await db.transaction((tx) async {
        await tx.table('users').where('name', 'A').decrement('balance', 100);
        await tx.table('users').where('name', 'B').increment('balance', 100);
      });
      expect(
        (await db.table('users').where('name', 'B').first())!['balance'],
        100,
      );
    });

    test('rollback on failure and exception propagates', () async {
      await db.table('users').insert({
        'name': 'A',
        'email': 'a@x',
        'balance': 500,
      });
      await expectLater(
        db.transaction((tx) async {
          await tx.table('users').where('name', 'A').decrement('balance', 100);
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect((await db.table('users').first())!['balance'], 500);
      // pool is still usable afterwards
      expect(await db.table('users').count(), 1);
    });

    test(
      'constraint violation rolls back and surfaces QueryException',
      () async {
        await db.table('users').insert({'name': 'A', 'email': 'dup@x'});
        await expectLater(
          db.transaction((tx) async {
            await tx.table('users').insert({'name': 'B', 'email': 'b@x'});
            await tx.table('users').insert({'name': 'C', 'email': 'dup@x'});
          }),
          throwsA(isA<QueryException>()),
        );
        expect(await db.table('users').count(), 1);
      },
    );

    test('nested transactions use savepoints', () async {
      await db.transaction((tx) async {
        await tx.table('users').insert({'name': 'outer', 'email': 'o@x'});
        try {
          await tx.transaction((inner) async {
            await inner.table('users').insert({
              'name': 'inner',
              'email': 'i@x',
            });
            throw StateError('inner fails');
          });
        } on StateError {
          // swallowed: only inner work rolls back
        }
        await tx.transaction((inner) async {
          await inner.table('users').insert({
            'name': 'inner2',
            'email': 'i2@x',
          });
        });
      });
      final names = (await db.table('users').orderBy('id').get()).map(
        (r) => r['name'],
      );
      expect(names, ['outer', 'inner2']);
    });

    test('using a finished transaction throws', () async {
      late Transaction leaked;
      await db.transaction((tx) async => leaked = tx);
      await expectLater(
        leaked.table('users').get(),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  test('query errors are typed and do not leak bindings', () async {
    try {
      await db.table('nope').where('secret', 'hunter2').get();
      fail('should throw');
    } on QueryException catch (e) {
      expect(e.sql, contains('nope'));
      expect(e.toString(), isNot(contains('hunter2')));
    }
  });

  test('ping, stats and disconnect lifecycle', () async {
    expect(await db.ping(), isTrue);
    await manager.disconnect();
    expect(await db.ping(), isFalse);
    expect(() => manager.connection(), throwsA(isA<ConfigurationException>()));
  });

  test('named connections and default selection', () async {
    final m = DatabaseManager();
    await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
    await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
      name: 'analytics',
    );
    await m.statement('CREATE TABLE a (x)');
    await m.connection('analytics').statement('CREATE TABLE b (x)');
    expect(
      await m.select("SELECT name FROM sqlite_master WHERE name = 'a'"),
      hasLength(1),
    );
    expect(
      await m
          .connection('analytics')
          .select("SELECT name FROM sqlite_master WHERE name = 'a'"),
      isEmpty,
    );
    await m.disconnect();
  });

  test('file database with pool > 1 and concurrent queries', () async {
    final dir = Directory.systemTemp.createTempSync('dc_sqlite');
    final m = DatabaseManager();
    final fdb = await m.connect(
      ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: '${dir.path}/t.sqlite',
        maxPoolSize: 4,
      ),
    );
    await fdb.statement('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await Future.wait([
      for (var i = 0; i < 20; i++) fdb.table('t').insert({'v': i}),
    ]);
    expect(await fdb.table('t').count(), 20);
    await m.disconnect();
    dir.deleteSync(recursive: true);
  });

  test('missing adapter gives an actionable error', () async {
    final m = DatabaseManager(drivers: const {});
    DatabaseManager.registeredDrivers.remove(DatabaseDriver.mssql);
    await expectLater(
      m.connect(
        const ConnectionConfig(driver: DatabaseDriver.mssql, database: 'x'),
      ),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test('bad path surfaces ConnectionException', () async {
    final m = DatabaseManager();
    await expectLater(
      m.connect(
        const ConnectionConfig(
          driver: DatabaseDriver.sqlite,
          database: '/nonexistent_dir/x/y.sqlite',
        ),
      ),
      throwsA(isA<ConnectionException>()),
    );
  });

  group('error details', () {
    test('table already exists', () async {
      await expectLater(
        db.statement('CREATE TABLE users (id INTEGER)'),
        throwsA(
          isA<QueryException>()
              .having((e) => e.message, 'message', startsWith('Database query'))
              .having((e) => e.details, 'details', contains('already exists'))
              .having((e) => e.hint, 'hint', contains('migration'))
              .having((e) => e.toString(), 'toString', contains('Details:')),
        ),
      );
    });

    test('unique violation', () async {
      await db.statement("INSERT INTO users (name, email) VALUES ('a', 'e@x')");
      await expectLater(
        db.statement("INSERT INTO users (name, email) VALUES ('b', 'e@x')"),
        throwsA(
          isA<QueryException>()
              .having((e) => e.details, 'details', contains('users.email'))
              .having((e) => e.hint, 'hint', contains('Unique')),
        ),
      );
    });

    test('missing table', () async {
      await expectLater(
        db.statement('SELECT * FROM nope'),
        throwsA(
          isA<QueryException>()
              .having((e) => e.details, 'details', contains('no such table'))
              .having((e) => e.hint, 'hint', contains('migrations')),
        ),
      );
    });
  });
}
