import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

/// The spec's headline example, end to end (SQLite so it runs anywhere).
void main() {
  setUpAll(registerSqlite);

  test('the "five minute API" works exactly as written in the vision', () async {
    final manager = DatabaseManager();
    DB.use(manager);
    await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
    await DB.statement(
      'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT UNIQUE)',
    );

    final app = DartCore(
      config: const AppConfig(environment: AppEnvironment.testing),
      logger: Logger(level: LogLevel.fatal, handlers: []),
    );

    app.get('/users', (request) async {
      final users = await DB.table('users').get();
      return Response.ok(users);
    });

    app.post('/users', (request) async {
      final data = await request.json();
      final user = await DB.table('users').insert(data);
      return Response.created(user);
    });

    app.get('/users/:id', (request) async {
      final user = await DB.table('users').find(request.param('id')!);
      if (user == null) return Response.notFound({'message': 'User not found'});
      return Response.ok({'success': true, 'data': user});
    });

    final created = await app.send(
      'POST',
      '/users',
      body: {'name': 'John', 'email': 'john@example.com'},
    );
    expect(created.statusCode, 201);
    expect((await created.readJson() as Map)['name'], 'John');

    final list = await app.send('GET', '/users');
    expect(await list.readJson(), [
      {'id': 1, 'name': 'John', 'email': 'john@example.com'},
    ]);

    final one = await app.send('GET', '/users/1');
    expect(((await one.readJson()) as Map)['success'], true);
    final missing = await app.send('GET', '/users/99');
    expect(missing.statusCode, 404);
    expect(await missing.readJson(), {'message': 'User not found'});

    // Constraint violations surface as safe 500s, not driver internals.
    final dup = await app.send(
      'POST',
      '/users',
      body: {'name': 'X', 'email': 'john@example.com'},
    );
    expect(dup.statusCode, 500);
    expect(await dup.readText(), isNot(contains('UNIQUE')));
    await DB.reset();
  });

  test('core works without any database', () async {
    final app = DartCore(
      config: const AppConfig(environment: AppEnvironment.testing),
      database: DatabaseManager(),
    );
    app.get('/ping', (r) => Response.success({'pong': true}, message: 'ok'));
    final res = await app.send('GET', '/ping');
    expect((await res.readJson() as Map)['data'], {'pong': true});
    await expectLater(
      Future<void>.sync(() => app.database.table('x')),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test('instance-based usage and isolation between managers', () async {
    final a = DatabaseManager(), b = DatabaseManager();
    final cfg = const ConnectionConfig(
      driver: DatabaseDriver.sqlite,
      database: ':memory:',
    );
    await a.connect(cfg);
    await b.connect(cfg);
    await a.statement('CREATE TABLE t (x)');
    final appA = DartCore(
      config: const AppConfig(environment: AppEnvironment.testing),
      database: a,
    );
    await appA.database.table('t').insert({'x': 1});
    expect(await a.table('t').count(), 1);
    await expectLater(b.table('t').count(), throwsA(isA<QueryException>()));
    await a.disconnect();
    await b.disconnect();
  });

  test('graceful stop disconnects the database', () async {
    final m = DatabaseManager();
    await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
    final app = DartCore(
      config: const AppConfig(environment: AppEnvironment.testing),
      database: m,
    );
    await app.start(port: 0, handleSignals: false);
    await app.stop();
    expect(() => m.connection(), throwsA(isA<ConfigurationException>()));
  });

  test('DB-backed unique/exists validation', () async {
    final m = DatabaseManager();
    final db = await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
    await db.statement(
      'CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)',
    );
    await db.table('users').insert({'email': 'taken@x.io'});
    final checker = databaseExistenceChecker(db);
    final r = await Validate.requestAsync(
      {'email': 'taken@x.io'},
      {'email': 'required|email|unique:users,email'},
      exists: checker,
    );
    expect(r.errors['email'], isNotEmpty);
    // updating own record: ignore id 1
    final ok = await Validate.requestAsync(
      {'email': 'taken@x.io'},
      {'email': 'unique:users,email,1'},
      exists: checker,
    );
    expect(ok.passes, isTrue);
    // hostile rule strings can't inject
    await expectLater(
      Validate.requestAsync(
        {'e': 'a'},
        {'e': 'unique:users;DROP TABLE users,email'},
        exists: checker,
      ),
      throwsA(isA<QueryException>()),
    );
    await m.disconnect();
  });
}
