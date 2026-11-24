import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  const pg = PostgresDialect(),
      my = MySqlDialect(),
      lite = SqliteDialect(),
      ms = MssqlDialect();

  group('select compilation', () {
    test('postgres', () {
      final q = qb(pg, 'users')
          .select(['id', 'name'])
          .where('status', 'active')
          .where('age', '>=', 18)
          .orderBy('created_at', descending: true)
          .limit(20)
          .offset(40)
          .toCompiled();
      expect(
        q.sql,
        'SELECT "id", "name" FROM "users" WHERE "status" = \$1 AND "age" >= \$2 ORDER BY "created_at" DESC LIMIT 20 OFFSET 40',
      );
      expect(q.bindings, ['active', 18]);
    });

    test('mysql uses backticks and ?', () {
      final q = qb(my, 'users').where('a', 1).toCompiled();
      expect(q.sql, 'SELECT * FROM `users` WHERE `a` = ?');
    });

    test('mssql uses brackets, @pN and OFFSET/FETCH', () {
      final q = qb(ms, 'users').where('a', 1).limit(5).toCompiled();
      expect(
        q.sql,
        'SELECT * FROM [users] WHERE [a] = @p1 ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY',
      );
      final ordered = qb(
        ms,
        'u',
      ).orderBy('id').limit(5).offset(10).toCompiled();
      expect(
        ordered.sql,
        'SELECT * FROM [u] ORDER BY [id] ASC OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY',
      );
    });

    test('offset without limit is dialect-correct', () {
      expect(
        qb(lite, 't').offset(3).toCompiled().sql,
        endsWith('LIMIT -1 OFFSET 3'),
      );
      expect(
        qb(my, 't').offset(3).toCompiled().sql,
        endsWith('LIMIT 18446744073709551615 OFFSET 3'),
      );
      expect(qb(pg, 't').offset(3).toCompiled().sql, endsWith('OFFSET 3'));
    });

    test('null handling, in, between, like, groups, or', () {
      final q = qb(pg, 'users')
          .where('deleted_at', null)
          .where('x', '!=', null)
          .whereIn('id', [1, 2, 3])
          .whereNotIn('r', ['a'])
          .whereBetween('age', 1, 9)
          .whereLike('name', 'jo%')
          .whereNull('a')
          .whereNotNull('b')
          .whereGroup(
            (g) => g.where('role', 'admin').orWhere('role', 'manager'),
          )
          .orWhere('z', 1)
          .toCompiled();
      expect(
        q.sql,
        'SELECT * FROM "users" WHERE "deleted_at" IS NULL AND "x" IS NOT NULL '
        'AND "id" IN (\$1, \$2, \$3) AND "r" NOT IN (\$4) AND "age" BETWEEN \$5 AND \$6 '
        'AND "name" LIKE \$7 AND "a" IS NULL AND "b" IS NOT NULL '
        'AND ("role" = \$8 OR "role" = \$9) OR "z" = \$10',
      );
      expect(q.bindings, [1, 2, 3, 'a', 1, 9, 'jo%', 'admin', 'manager', 1]);
    });

    test('empty IN compiles to constant false, never invalid SQL', () {
      expect(
        qb(pg, 't').whereIn('id', []).toCompiled().sql,
        'SELECT * FROM "t" WHERE 1 = 0',
      );
      expect(
        qb(pg, 't').whereNotIn('id', []).toCompiled().sql,
        'SELECT * FROM "t" WHERE 1 = 1',
      );
    });

    test('joins, group by, having, distinct, aliases', () {
      final q = qb(pg, 'users as u')
          .distinct()
          .select(['u.id', 'p.title as post_title'])
          .join('posts as p', 'p.user_id', '=', 'u.id')
          .leftJoin('c', 'c.id', '=', 'u.cid')
          .groupBy(['u.id'])
          .havingRaw('COUNT(*) > ?', [2])
          .toCompiled();
      expect(
        q.sql,
        'SELECT DISTINCT "u"."id", "p"."title" AS "post_title" FROM "users" AS "u" '
        'INNER JOIN "posts" AS "p" ON "p"."user_id" = "u"."id" '
        'LEFT JOIN "c" ON "c"."id" = "u"."cid" GROUP BY "u"."id" HAVING (COUNT(*) > \$1)',
      );
    });

    test('when() applies conditionally', () {
      String? pick(bool on) => on ? 'x' : null;
      var search = pick(false);
      final a = qb(
        pg,
        't',
      ).when(search != null, (q) => q.where('n', search)).toCompiled();
      expect(a.sql, 'SELECT * FROM "t"');
      search = pick(true);
      final b = qb(
        pg,
        't',
      ).when(search != null, (q) => q.where('n', search)).toCompiled();
      expect(b.bindings, ['x']);
    });

    test('raw placeholders are translated and quotes respected', () {
      final q = qb(
        pg,
        't',
      ).whereRaw("note = '?' AND a = ? AND b > ?", [1, 2]).toCompiled();
      expect(
        q.sql,
        "SELECT * FROM \"t\" WHERE (note = '?' AND a = \$1 AND b > \$2)",
      );
      expect(
        () => qb(pg, 't').whereRaw('a = ?', []).toCompiled(),
        throwsA(isA<QueryException>()),
      );
      expect(
        () => qb(pg, 't').whereRaw('a = 1', [1]).toCompiled(),
        throwsA(isA<QueryException>()),
      );
    });
  });

  group('SQL safety', () {
    test('malicious identifiers are rejected', () {
      for (final bad in [
        'id; DROP TABLE users',
        'a" OR "1"="1',
        'a b',
        "a'",
        '',
        'a..b',
        '1a',
      ]) {
        expect(
          () => qb(pg, 't').where(bad, 1).toCompiled(),
          throwsA(isA<QueryException>()),
          reason: bad,
        );
        expect(
          () => qb(pg, 't').orderBy(bad).toCompiled(),
          throwsA(isA<QueryException>()),
          reason: bad,
        );
      }
      expect(
        () => qb(pg, 'users; DROP TABLE x'),
        throwsA(isA<QueryException>()),
      );
    });

    test('values never appear in SQL text', () {
      const evil = "'; DROP TABLE users; --";
      final q = qb(pg, 'users').where('name', evil).toCompiled();
      expect(q.sql, isNot(contains('DROP')));
      expect(q.bindings, [evil]);
    });

    test('unknown operators rejected; ILIKE only on postgres', () {
      expect(
        () => qb(pg, 't').where('a', '= 1 OR 1=1 --', 1).toCompiled(),
        throwsA(isA<QueryException>()),
      );
      expect(
        qb(pg, 't').where('a', 'ilike', 'x').toCompiled().sql,
        contains('ILIKE'),
      );
      expect(
        () => qb(my, 't').where('a', 'ilike', 'x').toCompiled(),
        throwsA(isA<QueryException>()),
      );
    });

    test('orderByAllowed whitelists request-driven columns', () {
      final q = qb(pg, 't').orderByAllowed('name; DROP', [
        'name',
        'id',
      ], fallback: 'id').toCompiled();
      expect(q.sql, 'SELECT * FROM "t" ORDER BY "id" ASC');
      expect(
        qb(pg, 't').orderByAllowed('name', ['name']).toCompiled().sql,
        endsWith('"name" ASC'),
      );
    });

    test('update/delete without where are refused', () async {
      final b = qb(pg, 't');
      expect(() => b.update({'a': 1}), throwsA(isA<QueryException>()));
      expect(() => b.delete(), throwsA(isA<QueryException>()));
      expect(() => b.increment('a'), throwsA(isA<QueryException>()));
    });
  });

  group('writes', () {
    test('insert per dialect', () async {
      for (final (d, sql) in [
        (pg, 'INSERT INTO "u" ("a", "b") VALUES (\$1, \$2) RETURNING *'),
        (my, 'INSERT INTO `u` (`a`, `b`) VALUES (?, ?)'),
        (lite, 'INSERT INTO "u" ("a", "b") VALUES (?, ?) RETURNING *'),
        (ms, 'INSERT INTO [u] ([a], [b]) OUTPUT INSERTED.* VALUES (@p1, @p2)'),
      ]) {
        final e = RecordingExecutor();
        await qb(d, 'u', e).insert({'a': 1, 'b': 'x'});
        expect(e.last.sql, sql, reason: d.name);
        expect(e.last.bindings, [1, 'x']);
      }
    });

    test('mysql insert re-reads by insertId', () async {
      final e = RecordingExecutor()
        ..reply = (q) => q.sql.startsWith('INSERT')
            ? const QueryResult(insertId: 7, affectedRows: 1)
            : QueryResult(
                rows: [
                  {'id': 7, 'a': 1},
                ],
              );
      final row = await qb(my, 'u', e).insert({'a': 1});
      expect(row, {'id': 7, 'a': 1});
      expect(e.last.sql, 'SELECT * FROM `u` WHERE `id` = ? LIMIT 1');
    });

    test('insertMany validates uniform keys and chunks', () async {
      final e = RecordingExecutor();
      await qb(pg, 'u', e).insertMany([
        {'a': 1},
        {'a': 2},
      ]);
      expect(e.last.sql, 'INSERT INTO "u" ("a") VALUES (\$1), (\$2)');
      expect(
        () => qb(pg, 'u', e).insertMany([
          {'a': 1},
          {'b': 2},
        ]),
        throwsA(isA<QueryException>()),
      );
      final big = RecordingExecutor();
      await qb(
        ms,
        'u',
        big,
      ).insertMany(List.generate(2500, (i) => {'a': i, 'b': i}));
      expect(big.queries.length, greaterThan(1));
      expect(big.queries.every((q) => q.bindings.length <= 2100), isTrue);
    });

    test('update, increment, decrement, delete', () async {
      final e = RecordingExecutor();
      await qb(pg, 'a', e).where('id', 1).update({'x': 2});
      expect(e.last.sql, 'UPDATE "a" SET "x" = \$1 WHERE "id" = \$2');
      await qb(pg, 'a', e).where('id', 1).decrement('balance', 100);
      expect(
        e.last.sql,
        'UPDATE "a" SET "balance" = "balance" + \$1 WHERE "id" = \$2',
      );
      expect(e.last.bindings, [-100, 1]);
      await qb(pg, 'a', e).where('id', 1).delete();
      expect(e.last.sql, 'DELETE FROM "a" WHERE "id" = \$1');
      await qb(lite, 'a', e).truncate();
      expect(e.last.sql, 'DELETE FROM "a"');
      await qb(pg, 'a', e).truncate();
      expect(e.last.sql, 'TRUNCATE TABLE "a"');
    });
  });

  group('aggregates & pagination', () {
    test('count wraps distinct/limit queries', () async {
      final e = RecordingExecutor()
        ..reply = (_) => QueryResult(
          rows: [
            {'aggregate': '5'},
          ],
        );
      expect(await qb(pg, 'u', e).where('a', 1).count(), 5);
      expect(
        e.last.sql,
        'SELECT COUNT(*) AS aggregate FROM "u" WHERE "a" = \$1',
      );
      await qb(pg, 'u', e).distinct().select(['a']).count();
      expect(
        e.last.sql,
        contains('FROM (SELECT DISTINCT "a" FROM "u") AS "dc_sub"'),
      );
      await qb(pg, 'u', e).sum('amount');
      expect(e.last.sql, 'SELECT SUM("amount") AS aggregate FROM "u"');
    });

    test('exists issues SELECT 1 ... LIMIT 1', () async {
      final e = RecordingExecutor()
        ..reply = (_) => const QueryResult(
          rows: [
            {'dc_exists': 1},
          ],
        );
      expect(await qb(pg, 'u', e).where('a', 1).exists(), isTrue);
      expect(
        e.last.sql,
        'SELECT 1 AS dc_exists FROM "u" WHERE "a" = \$1 LIMIT 1',
      );
    });

    test('paginator math', () {
      const p = Paginator(data: [], currentPage: 2, perPage: 20, total: 41);
      expect(p.lastPage, 3);
      expect(p.hasNextPage, isTrue);
      expect(p.hasPreviousPage, isTrue);
      expect(
        const Paginator(
          data: [],
          currentPage: 1,
          perPage: 20,
          total: 0,
        ).lastPage,
        1,
      );
    });

    test('paginate runs count then page query', () async {
      final e = RecordingExecutor()
        ..reply = (q) => q.sql.contains('COUNT')
            ? QueryResult(
                rows: [
                  {'aggregate': 45},
                ],
              )
            : QueryResult(
                rows: [
                  {'id': 1},
                ],
              );
      final p = await qb(pg, 'u', e).orderBy('id').paginate(page: 3, limit: 20);
      expect(p.total, 45);
      expect(p.lastPage, 3);
      expect(e.queries.first.sql, isNot(contains('ORDER BY')));
      expect(e.last.sql, endsWith('ORDER BY "id" ASC LIMIT 20 OFFSET 40'));
      expect(
        () => qb(pg, 'u', e).paginate(page: 0),
        throwsA(isA<QueryException>()),
      );
    });
  });
}
