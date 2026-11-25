import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:test/test.dart';

/// Per-engine pieces of the contract suite: connection + DDL spelling.
class EngineSpec {
  EngineSpec({
    required this.name,
    required this.config,
    required this.idColumn,
    required this.boolType,
    this.boolTrue = '1',
    required this.dropIfExists,
    this.supportsSavepoints = true,
    this.timestampType = 'TIMESTAMP',
  });

  final String name;
  final ConnectionConfig config;

  /// Column definition for an auto-increment integer primary key named `id`.
  final String idColumn;
  final String boolType;

  /// Literal for boolean true in DDL defaults.
  final String boolTrue;
  final String Function(String table) dropIfExists;
  final bool supportsSavepoints;

  /// Column type for a nullable date-time (`TIMESTAMP` is `rowversion` on SQL Server).
  final String timestampType;
}

/// Behaviour every adapter must exhibit identically. Application CRUD code
/// must not change when the database changes.
void runContract(EngineSpec e, {required Future<void> Function() register}) {
  late DatabaseManager manager;
  Database? db;
  String? unreachable;

  setUpAll(() async {
    await register();
    manager = DatabaseManager();
    try {
      db = await manager.connect(e.config);
    } on ConnectionException catch (err) {
      unreachable =
          '${e.name} not reachable (${err.cause}). '
          'Start it with: docker compose -f integration_tests/docker-compose.yml up -d';
    }
  });
  tearDownAll(() => manager.disconnect());

  setUp(() async {
    if (db == null) {
      markTestSkipped(unreachable!);
      return;
    }
    for (final t in ['dc_posts', 'dc_users']) {
      await db!.statement(e.dropIfExists(t));
    }
    await db!.statement(
      'CREATE TABLE dc_users (id ${e.idColumn}, name VARCHAR(100) NOT NULL, '
      'email VARCHAR(100) UNIQUE, active ${e.boolType} NOT NULL DEFAULT ${e.boolTrue}, '
      'balance DECIMAL(12,2) NOT NULL DEFAULT 0, created_at ${e.timestampType} NULL)',
    );
    await db!.statement(
      'CREATE TABLE dc_posts (id ${e.idColumn}, user_id INT, title VARCHAR(100))',
    );
  });

  Database d() => db!;

  test('connection is healthy', () async {
    if (db == null) return;
    expect(await d().ping(), isTrue);
  });

  test('CRUD round trip returns stored row', () async {
    if (db == null) return;
    final row = await d().table('dc_users').insert({
      'name': 'John',
      'email': 'j@x.io',
    });
    expect(row['id'], isA<int>());
    expect(row['name'], 'John');
    final id = row['id']!;
    expect((await d().table('dc_users').find(id))!['email'], 'j@x.io');
    expect(
      await d().table('dc_users').where('id', id).update({'name': 'Jon'}),
      1,
    );
    expect((await d().table('dc_users').find(id))!['name'], 'Jon');
    expect(await d().table('dc_users').where('id', id).delete(), 1);
    expect(await d().table('dc_users').find(id), isNull);
  });

  test('insertMany + aggregates + exists', () async {
    if (db == null) return;
    await d().table('dc_users').insertMany([
      {'name': 'A', 'email': 'a@x', 'balance': 10},
      {'name': 'B', 'email': 'b@x', 'balance': 20.5},
      {'name': 'C', 'email': 'c@x', 'balance': 30},
    ]);
    expect(await d().table('dc_users').count(), 3);
    expect(await d().table('dc_users').sum('balance'), 60.5);
    expect(await d().table('dc_users').max('balance'), 30);
    expect(await d().table('dc_users').where('name', 'B').exists(), isTrue);
    expect(await d().table('dc_users').where('name', 'Z').exists(), isFalse);
  });

  test('where variants', () async {
    if (db == null) return;
    await d().table('dc_users').insertMany([
      {'name': 'Ann', 'email': 'a@x', 'balance': 1},
      {'name': 'Bob', 'email': 'b@x', 'balance': 2},
      {'name': 'Cat', 'email': null, 'balance': 3},
    ]);
    QueryBuilder t() => d().table('dc_users');
    expect(await t().whereIn('name', ['Ann', 'Cat']).count(), 2);
    expect(await t().whereNotIn('name', ['Ann']).count(), 2);
    expect(await t().whereNull('email').count(), 1);
    expect(await t().whereBetween('balance', 2, 3).count(), 2);
    expect(await t().whereLike('name', 'B%').count(), 1);
    expect(await t().whereIn('name', []).count(), 0);
    expect(
      await t()
          .whereGroup((q) => q.where('name', 'Ann').orWhere('name', 'Bob'))
          .count(),
      2,
    );
    expect(await t().whereRaw('balance > ?', [1]).count(), 2);
    final rows = await t()
        .orderBy('balance', descending: true)
        .limit(2)
        .offset(1)
        .get();
    expect(rows.map((r) => r['name']), ['Bob', 'Ann']);
  });

  test('joins', () async {
    if (db == null) return;
    final u = await d().table('dc_users').insert({'name': 'A', 'email': 'a@x'});
    await d().table('dc_posts').insertMany([
      {'user_id': u['id'], 'title': 'one'},
      {'user_id': u['id'], 'title': 'two'},
    ]);
    final rows = await d()
        .table('dc_users')
        .select(['dc_users.name', 'dc_posts.title'])
        .join('dc_posts', 'dc_posts.user_id', '=', 'dc_users.id')
        .orderBy('dc_posts.title')
        .get();
    expect(rows.map((r) => r['title']), ['one', 'two']);
    expect(
      await d()
          .table('dc_users')
          .leftJoin('dc_posts', 'dc_posts.user_id', '=', 'dc_users.id')
          .count(),
      2,
    );
  });

  test('pagination', () async {
    if (db == null) return;
    await d().table('dc_users').insertMany([
      for (var i = 1; i <= 45; i++) {'name': 'u$i', 'email': 'u$i@x'},
    ]);
    final p = await d()
        .table('dc_users')
        .orderBy('id')
        .paginate(page: 2, limit: 20);
    expect(p.total, 45);
    expect(p.lastPage, 3);
    expect(p.data.first['name'], 'u21');
    expect(p.hasNextPage && p.hasPreviousPage, isTrue);
  });

  test('data types round trip', () async {
    if (db == null) return;
    final t = DateTime.utc(2025, 1, 2, 3, 4, 5);
    final row = await d().table('dc_users').insert({
      'name': 'Zoë 日本語 🚀',
      'email': 't@x',
      'active': false,
      'balance': 1234.5,
      'created_at': t,
    });
    expect(row['name'], 'Zoë 日本語 🚀');
    expect(row['active'] == false || row['active'] == 0, isTrue);
    expect(num.parse(row['balance'].toString()), 1234.5);
    final created = row['created_at'];
    final text = '$created';
    final parsed = created is DateTime
        ? created.toUtc()
        : DateTime.parse(text.endsWith('Z') ? text : '${text}Z');
    expect(parsed, t);
  });

  test('SQL injection is inert', () async {
    if (db == null) return;
    const evil = "x'); DROP TABLE dc_users; --";
    await d().table('dc_users').insert({'name': evil, 'email': 'e@x'});
    expect(
      (await d().table('dc_users').where('name', evil).first())!['name'],
      evil,
    );
    expect(await d().table('dc_users').count(), 1);
  });

  group('transactions', () {
    test('commit', () async {
      if (db == null) return;
      await d().table('dc_users').insertMany([
        {'name': 'A', 'email': 'a@x', 'balance': 500},
        {'name': 'B', 'email': 'b@x', 'balance': 0},
      ]);
      await d().transaction((tx) async {
        await tx.table('dc_users').where('name', 'A').decrement('balance', 100);
        await tx.table('dc_users').where('name', 'B').increment('balance', 100);
      });
      expect(
        await d().table('dc_users').where('name', 'B').sum('balance'),
        100,
      );
      expect(
        await d().table('dc_users').where('name', 'A').sum('balance'),
        400,
      );
    });

    test('rollback on exception, error propagates', () async {
      if (db == null) return;
      await d().table('dc_users').insert({
        'name': 'A',
        'email': 'a@x',
        'balance': 500,
      });
      await expectLater(
        d().transaction((tx) async {
          await tx
              .table('dc_users')
              .where('name', 'A')
              .decrement('balance', 100);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(await d().table('dc_users').sum('balance'), 500);
    });

    test('constraint violation -> QueryException and rollback', () async {
      if (db == null) return;
      await d().table('dc_users').insert({'name': 'A', 'email': 'dup@x'});
      await expectLater(
        d().transaction((tx) async {
          await tx.table('dc_users').insert({'name': 'B', 'email': 'b@x'});
          await tx.table('dc_users').insert({'name': 'C', 'email': 'dup@x'});
        }),
        throwsA(isA<QueryException>()),
      );
      expect(await d().table('dc_users').count(), 1);
      expect(await d().ping(), isTrue, reason: 'pool must stay usable');
    });

    test('nested transactions via savepoints', () async {
      if (db == null) return;
      await d().transaction((tx) async {
        await tx.table('dc_users').insert({'name': 'outer', 'email': 'o@x'});
        try {
          await tx.transaction((inner) async {
            await inner.table('dc_users').insert({
              'name': 'inner',
              'email': 'i@x',
            });
            throw StateError('inner');
          });
        } on StateError {
          /* swallowed */
        }
        await tx.transaction((inner) async {
          await inner.table('dc_users').insert({
            'name': 'inner2',
            'email': 'i2@x',
          });
        });
      });
      final names = (await d().table('dc_users').orderBy('id').get()).map(
        (r) => r['name'],
      );
      expect(names, ['outer', 'inner2']);
    });
  });

  test('errors are typed and never leak bound values', () async {
    if (db == null) return;
    try {
      await d().table('dc_missing_table').where('secret', 'hunter2').get();
      fail('expected QueryException');
    } on QueryException catch (err) {
      expect(err.toString(), isNot(contains('hunter2')));
      expect(err.message, isNot(contains('hunter2')));
    }
  });

  test('concurrent queries share a bounded pool', () async {
    if (db == null) return;
    final results = await Future.wait([
      for (var i = 0; i < 30; i++)
        d().table('dc_users').insert({'name': 'c$i', 'email': 'c$i@x'}),
    ]);
    expect(results, hasLength(30));
    expect(await d().table('dc_users').count(), 30);
  });

  test('bad credentials surface ConnectionException', () async {
    if (db == null) return;
    final bad = ConnectionConfig(
      driver: e.config.driver,
      host: e.config.host,
      port: e.config.port,
      database: e.config.database,
      username: e.config.username,
      password: 'definitely-wrong',
      connectTimeout: const Duration(seconds: 5),
    );
    if (e.config.driver == DatabaseDriver.sqlite) return;
    await expectLater(
      DatabaseManager().connect(bad),
      throwsA(isA<ConnectionException>()),
    );
  });
}
