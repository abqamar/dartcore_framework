import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:tasks_api/auth/auth.dart';
import 'package:tasks_api/routes/api.dart';
import 'package:test/test.dart';

import '../database/migrations/index.dart';

void main() {
  late DartCore app;

  setUp(() async {
    // An in-memory SQLite database per test: fast, and no server is needed.
    registerSqlite();
    Config.reset();
    Config.set('JWT_SECRET', 'a-test-secret-that-is-at-least-32-bytes-long!');
    await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
    await Migrator(DB.connection(), migrations).migrate();
    await configureAuth();
    app = DartCore(
      database: DB.manager,
      logger: Logger(level: LogLevel.fatal, handlers: []),
    );
    registerRoutes(app);
  });

  tearDown(DB.reset);

  Future<String> register(String email) async {
    final r = await app.send(
      'POST',
      '/auth/register',
      body: {
        'name': 'Test User',
        'email': email,
        'password': 'correct horse battery',
      },
    );
    expect(r.statusCode, 201);
    final body = (await r.readJson()) as Map<String, dynamic>;
    return body['data']['access_token'] as String;
  }

  Map<String, String> bearer(String token) => {
    'authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> body(Response r) async =>
      (await r.readJson()) as Map<String, dynamic>;

  test('health is public', () async {
    final r = await app.send('GET', '/health');
    expect(r.statusCode, 200);
  });

  test('tasks require a token', () async {
    expect((await app.send('GET', '/api/tasks')).statusCode, 401);
    expect(
      (await app.send('POST', '/api/tasks', body: {'title': 'x'})).statusCode,
      401,
    );
  });

  test('create, list with filters, update and delete a task', () async {
    final token = await register('ada@example.com');

    final created = await app.send(
      'POST',
      '/api/tasks',
      headers: bearer(token),
      body: {'title': 'Write the tutorial', 'status': 'doing'},
    );
    expect(created.statusCode, 201);
    final task = (await body(created))['data'] as Map<String, dynamic>;
    expect(task['status'], 'doing');
    final id = task['id'];

    await app.send(
      'POST',
      '/api/tasks',
      headers: bearer(token),
      body: {'title': 'Ship it'},
    );

    var list = await body(
      await app.send('GET', '/api/tasks?status=doing', headers: bearer(token)),
    );
    expect((list['data'] as List), hasLength(1));
    list = await body(
      await app.send('GET', '/api/tasks?q=Ship', headers: bearer(token)),
    );
    expect((list['data'] as List).single['title'], 'Ship it');
    expect((list['meta'] as Map)['total'], 1);

    final updated = await app.send(
      'PUT',
      '/api/tasks/$id',
      headers: bearer(token),
      body: {'status': 'done'},
    );
    expect((await body(updated))['data']['status'], 'done');

    final deleted = await app.send(
      'DELETE',
      '/api/tasks/$id',
      headers: bearer(token),
    );
    expect(deleted.statusCode, 204);
    final gone = await app.send(
      'GET',
      '/api/tasks/$id',
      headers: bearer(token),
    );
    expect(gone.statusCode, 404);
  });

  test('invalid input is rejected with field errors', () async {
    final token = await register('ada@example.com');
    final r = await app.send(
      'POST',
      '/api/tasks',
      headers: bearer(token),
      body: {'title': 'x', 'status': 'later'},
    );
    expect(r.statusCode, 422);
    final errors = (await body(r))['errors'] as Map<String, dynamic>;
    expect(errors.keys, containsAll(['title', 'status']));
  });

  test('a user cannot read, change or delete another user\'s task', () async {
    final ada = await register('ada@example.com');
    final bob = await register('bob@example.com');
    final created = await app.send(
      'POST',
      '/api/tasks',
      headers: bearer(ada),
      body: {'title': 'Ada only'},
    );
    final id = ((await body(created))['data'] as Map)['id'];

    for (final method in ['GET', 'PUT', 'DELETE']) {
      final r = await app.send(
        method,
        '/api/tasks/$id',
        headers: bearer(bob),
        body: method == 'PUT' ? {'title': 'hijacked'} : null,
      );
      expect(r.statusCode, 404, reason: method);
    }
    final bobsList = await body(
      await app.send('GET', '/api/tasks', headers: bearer(bob)),
    );
    expect(bobsList['data'], isEmpty);

    final still = await app.send('GET', '/api/tasks/$id', headers: bearer(ada));
    expect(still.statusCode, 200);
  });

  test('the Postgres adapter can be registered alongside SQLite', () {
    registerPostgres();
  });
}
