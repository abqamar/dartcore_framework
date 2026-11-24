import 'package:complete_application/app.dart';
import 'package:complete_application/migrations.dart';
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

const secret = 'example-secret-example-secret-example-secret-0123';

void main() {
  late DatabaseManager database;
  late DartCore app;

  setUpAll(registerSqlite);
  setUp(() async {
    database = DatabaseManager();
    final db = await database.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
    await Migrator(db, migrations).migrate();
    await DatabaseAuthStores.createTables(db);
    app = buildApp(
      database,
      jwtSecret: secret,
      logger: Logger(level: LogLevel.fatal, handlers: []),
    );
  });
  tearDown(() => database.disconnect());

  Future<Map<String, dynamic>> json(Response r) async =>
      (await r.readJson()) as Map<String, dynamic>;
  Map<String, String> bearer(String t) => {'authorization': 'Bearer $t'};

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
    return (await json(r))['data']['access_token'] as String;
  }

  Future<String> adminToken() async {
    await register('admin@example.com');
    await database.table('users').where('email', 'admin@example.com').update({
      'role': 'admin',
    });
    final r = await app.send(
      'POST',
      '/auth/login',
      body: {'email': 'admin@example.com', 'password': 'correct horse battery'},
    );
    return (await json(r))['data']['access_token'] as String;
  }

  test(
    'registration validates, rejects duplicates, never returns the password hash',
    () async {
      final bad = await app.send(
        'POST',
        '/auth/register',
        body: {'name': 'A', 'email': 'nope', 'password': 'x'},
      );
      expect(bad.statusCode, 422);
      expect((await json(bad))['errors'], containsPair('email', isNotEmpty));
      final token = await register('a@example.com');
      final dup = await app.send(
        'POST',
        '/auth/register',
        body: {
          'name': 'Dup',
          'email': 'A@example.com',
          'password': 'correct horse battery',
        },
      );
      expect(dup.statusCode, 422, reason: 'emails are case-insensitive');
      final me = await app.send('GET', '/auth/me', headers: bearer(token));
      expect((await me.readText()), isNot(contains('argon2')));
    },
  );

  test('login: wrong password and unknown user give the same 401', () async {
    await register('a@example.com');
    final wrong = await app.send(
      'POST',
      '/auth/login',
      body: {'email': 'a@example.com', 'password': 'nope-nope'},
    );
    final unknown = await app.send(
      'POST',
      '/auth/login',
      body: {'email': 'x@example.com', 'password': 'nope-nope'},
    );
    expect(wrong.statusCode, 401);
    expect(await wrong.readText(), await unknown.readText());
  });

  test('refresh rotates and replay is rejected', () async {
    final r = await app.send(
      'POST',
      '/auth/register',
      body: {
        'name': 'Ref',
        'email': 'r@example.com',
        'password': 'correct horse battery',
      },
    );
    final refresh = (await json(r))['data']['refresh_token'] as String;
    expect(
      (await app.send(
        'POST',
        '/auth/refresh',
        body: {'refresh_token': refresh},
      )).statusCode,
      200,
    );
    expect(
      (await app.send(
        'POST',
        '/auth/refresh',
        body: {'refresh_token': refresh},
      )).statusCode,
      401,
    );
  });

  test(
    'products: public read, admin-only write, validation, pagination, search, sorting',
    () async {
      // anonymous / non-admin cannot write
      expect(
        (await app.send(
          'POST',
          '/api/products',
          body: {'name': 'X', 'price': 1},
        )).statusCode,
        401,
      );
      final user = await register('u@example.com');
      expect(
        (await app.send(
          'POST',
          '/api/products',
          headers: bearer(user),
          body: {'name': 'Xx', 'price': 1},
        )).statusCode,
        403,
      );

      final admin = await adminToken();
      final invalid = await app.send(
        'POST',
        '/api/products',
        headers: bearer(admin),
        body: {'name': 'X', 'price': -5},
      );
      expect(invalid.statusCode, 422);

      for (var i = 1; i <= 25; i++) {
        final r = await app.send(
          'POST',
          '/api/products',
          headers: bearer(admin),
          body: {'name': 'Product $i', 'price': i * 1.5, 'stock': i},
        );
        expect(r.statusCode, 201);
      }
      final page2 = await json(
        await app.send(
          'GET',
          '/api/products?page=2&limit=10&sort=price&order=desc',
        ),
      );
      expect((page2['data'] as List).first['name'], 'Product 15');
      expect(page2['meta'], containsPair('total', 25));
      expect(page2['meta'], containsPair('last_page', 3));
      final search = await json(
        await app.send('GET', '/api/products?search=Product%202'),
      );
      expect(search['meta'], containsPair('total', 7)); // 2, 20..25
      // hostile sort column falls back safely instead of erroring or injecting
      final hostile = await app.send(
        'GET',
        '/api/products?sort=id;DROP%20TABLE%20products',
      );
      expect(hostile.statusCode, 200);
      expect(
        (await json(await app.send('GET', '/api/products')))['meta'],
        containsPair('total', 25),
      );
    },
  );

  test('products: update, 404s, delete', () async {
    final admin = await adminToken();
    final created = await json(
      await app.send(
        'POST',
        '/api/products',
        headers: bearer(admin),
        body: {'name': 'Widget', 'price': 9.99},
      ),
    );
    final id = created['data']['id'];
    final updated = await json(
      await app.send(
        'PUT',
        '/api/products/$id',
        headers: bearer(admin),
        body: {'stock': 5},
      ),
    );
    expect(updated['data']['stock'], 5);
    expect(
      (await app.send(
        'PUT',
        '/api/products/999',
        headers: bearer(admin),
        body: {'stock': 1},
      )).statusCode,
      404,
    );
    expect(
      (await app.send(
        'PUT',
        '/api/products/$id',
        headers: bearer(admin),
        body: {},
      )).statusCode,
      400,
    );
    expect(
      (await app.send(
        'DELETE',
        '/api/products/$id',
        headers: bearer(admin),
      )).statusCode,
      204,
    );
    expect((await app.send('GET', '/api/products/$id')).statusCode, 404);
  });
}
