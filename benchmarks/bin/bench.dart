import 'dart:async';
import 'dart:convert';

import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

/// Run (JIT):  dart run bin/bench.dart
/// Run (AOT):  dart compile exe bin/bench.dart -o /tmp/bench && /tmp/bench
/// Postgres numbers need: docker compose -f ../integration_tests/docker-compose.yml up -d postgres
///
/// These are micro-benchmarks on one machine: use them to compare changes, not
/// as a claim about production throughput.
Future<void> main() async {
  print('DartCore benchmarks  (${DateTime.now().toIso8601String()})');
  print(
    'Dart ${const String.fromEnvironment('dart.version', defaultValue: '')}',
  );
  await _queryBuilder();
  await _routing();
  _json();
  await _sqlite();
  await _postgres();
}

class _R {
  _R(this.name, this.n, this.micros);
  final String name;
  final int n;
  final int micros;
  void print_() => print(
    '${name.padRight(46)} ${(n * 1e6 / micros).toStringAsFixed(0).padLeft(10)} ops/s   '
    '${(micros / n).toStringAsFixed(2).padLeft(9)} us/op',
  );
}

Future<_R> _time(
  String name,
  int n,
  FutureOr<void> Function() body, {
  int warmup = 200,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    await body();
  }
  return _R(name, n, sw.elapsedMicroseconds)..print_();
}

class _Null implements DatabaseExecutor {
  @override
  Future<QueryResult> execute(CompiledQuery query) async => const QueryResult();
}

Future<void> _queryBuilder() async {
  print('\n== query builder (compile only, no I/O)');
  const d = PostgresDialect();
  await _time('simple select + where', 200000, () {
    QueryBuilder(
      _Null(),
      d,
      'users',
    ).where('status', 'active').orderBy('id').limit(20).toCompiled();
  });
  await _time('complex: join/group/in/between/having', 100000, () {
    QueryBuilder(_Null(), d, 'users as u')
        .select(['u.id', 'p.title'])
        .join('posts as p', 'p.user_id', '=', 'u.id')
        .whereIn('u.id', [1, 2, 3, 4, 5])
        .whereBetween('u.age', 18, 65)
        .whereGroup(
          (q) => q.where('u.role', 'admin').orWhere('u.role', 'manager'),
        )
        .groupBy(['u.id'])
        .havingRaw('COUNT(*) > ?', [2])
        .toCompiled();
  });
}

Future<void> _routing() async {
  print('\n== HTTP pipeline (in-process via app.send, no sockets)');
  final app = App(
    config: const AppConfig(
      environment: AppEnvironment.testing,
      requestIdAndLogging: false,
    ),
  );
  for (var i = 0; i < 100; i++) {
    app.get('/static/route$i', (r) => Response.ok({'i': i}));
    app.get(
      '/dyn$i/:id/items/:item',
      (r) => Response.ok({'id': r.param('id')}),
    );
  }
  app.post('/echo', (r) async => Response.ok(await r.json()));
  await _time(
    'static route (200 routes registered)',
    50000,
    () async => app.send('GET', '/static/route50'),
  );
  await _time(
    'param route, 2 params (last registered)',
    50000,
    () async => app.send('GET', '/dyn99/5/items/9'),
  );
  await _time(
    'POST JSON echo',
    30000,
    () async => app.send('POST', '/echo', body: {'a': 1, 'b': 'two'}),
  );
  await _time(
    '404 (exception path)',
    30000,
    () async => app.send('GET', '/missing'),
  );
}

void _json() {
  print('\n== JSON serialization');
  final rows = [
    for (var i = 0; i < 100; i++)
      {
        'id': i,
        'name': 'User $i',
        'email': 'u$i@x.io',
        'active': true,
        'created_at': DateTime.utc(2025),
      },
  ];
  var sw = Stopwatch()..start();
  const n = 5000;
  for (var i = 0; i < n; i++) {
    encodeJson(rows);
  }
  var us = sw.elapsedMicroseconds;
  print(
    '${'encodeJson 100 rows (DartCore, DateTime-aware)'.padRight(46)} ${(n * 1e6 / us).toStringAsFixed(0).padLeft(10)} ops/s   ${(us / n).toStringAsFixed(2).padLeft(9)} us/op',
  );
  final plain = [
    for (final r in rows) {...r, 'created_at': '2025-01-01T00:00:00.000Z'},
  ];
  sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    jsonEncode(plain);
  }
  us = sw.elapsedMicroseconds;
  print(
    '${'dart:convert jsonEncode 100 rows (baseline)'.padRight(46)} ${(n * 1e6 / us).toStringAsFixed(0).padLeft(10)} ops/s   ${(us / n).toStringAsFixed(2).padLeft(9)} us/op',
  );
}

Future<void> _crud(String label, Database db, String idCol) async {
  await db.statement('DROP TABLE IF EXISTS bench_t');
  await db.statement(
    'CREATE TABLE bench_t (id $idCol, name VARCHAR(50), n INT)',
  );
  print('\n== $label CRUD (through QueryBuilder + pool)');
  var i = 0;
  await _time(
    'insert (single row, returning)',
    2000,
    () async => db.table('bench_t').insert({'name': 'x${i++}', 'n': i}),
    warmup: 50,
  );
  await _time(
    'find by primary key',
    3000,
    () async => db.table('bench_t').find(1 + (i++ % 1000)),
    warmup: 50,
  );
  await _time(
    'select 100 rows',
    1000,
    () async => db.table('bench_t').limit(100).get(),
    warmup: 20,
  );
  await _time(
    'update by id',
    2000,
    () async =>
        db.table('bench_t').where('id', 1 + (i++ % 1000)).update({'n': i}),
    warmup: 50,
  );
  final sw = Stopwatch()..start();
  await db.table('bench_t').insertMany([
    for (var k = 0; k < 5000; k++) {'name': 'bulk', 'n': k},
  ]);
  print(
    '${'insertMany 5000 rows (chunked)'.padRight(46)} ${(5000 * 1e6 / sw.elapsedMicroseconds).toStringAsFixed(0).padLeft(10)} rows/s',
  );
  await db.statement('DROP TABLE bench_t');
}

Future<void> _sqlite() async {
  registerSqlite();
  final m = DatabaseManager();
  final db = await m.connect(
    const ConnectionConfig(driver: DatabaseDriver.sqlite, database: ':memory:'),
  );
  await _crud('SQLite (in-memory)', db, 'INTEGER PRIMARY KEY AUTOINCREMENT');
  await m.disconnect();
}

Future<void> _postgres() async {
  registerPostgres();
  final m = DatabaseManager();
  final Database db;
  try {
    db = await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.postgres,
        host: 'localhost',
        port: 54329,
        database: 'dartcore_test',
        username: 'dartcore',
        password: 'dartcore',
        maxPoolSize: 10,
      ),
    );
  } on ConnectionException {
    print('\n== PostgreSQL: skipped (not reachable on localhost:54329)');
    return;
  }
  await _crud(
    'PostgreSQL 16 (local docker, loopback)',
    db,
    'SERIAL PRIMARY KEY',
  );

  print('\n== connection pool behaviour (PostgreSQL)');
  await db.statement('DROP TABLE IF EXISTS bench_p');
  await db.statement('CREATE TABLE bench_p (id SERIAL PRIMARY KEY, v INT)');
  for (final conc in [1, 10, 50]) {
    final sw = Stopwatch()..start();
    const total = 2000;
    var next = 0;
    await Future.wait([
      for (var w = 0; w < conc; w++)
        () async {
          while (next < total) {
            final k = next++;
            await db.table('bench_p').insert({'v': k});
          }
        }(),
    ]);
    print(
      '${'$conc concurrent workers, pool max 10 ($total inserts)'.padRight(46)} ${(total * 1e6 / sw.elapsedMicroseconds).toStringAsFixed(0).padLeft(10)} ops/s   pool=${(db.adapter as PooledAdapter).stats}',
    );
  }
  await db.statement('DROP TABLE bench_p');
  await m.disconnect();
}
