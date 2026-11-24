// Passwords, JWT, refresh rotation and route protection with SQLite-backed stores (ran for real).
//
// Observed output of `dart run example/dartcore_auth_example.dart`:
//
//   hash prefix: $argon2id$v=19$m=194...
//   right password: true
//   wrong password: false
//   token_type=Bearer expires_in=900
//   GET /admin without token -> 401
//   GET /admin with token    -> 200
//   refreshed: true
//   replayed refresh token -> AuthenticationException

import 'dart:convert';
import 'dart:math';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

class DemoUsers implements UserRepository {
  final _users = const {
    '1': AuthUser(id: 1, email: 'admin@example.com', roles: ['admin']),
  };

  @override
  Future<AuthUser?> findById(String id) async => _users[id];
}

Future<void> main() async {
  registerSqlite();
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
  await DatabaseAuthStores.createTables(DB.connection());

  // In a real app the secret comes from Config.require('JWT_SECRET').
  final rnd = Random.secure();
  final secret = base64Url.encode(List.generate(48, (_) => rnd.nextInt(256)));

  final auth = AuthService(
    secret: secret,
    users: DemoUsers(),
    stores: DatabaseAuthStores(DB.connection()).stores,
  );

  // Passwords: Argon2id, constant-time verification.
  final hash = await auth.hashPassword('correct horse battery staple');
  print('hash prefix: ${hash.substring(0, 20)}...');
  print(
    'right password: ${await auth.checkPassword('correct horse battery staple', hash)}',
  );
  print('wrong password: ${await auth.checkPassword('nope', hash)}');

  // Tokens: short-lived JWT access token + rotating opaque refresh token.
  final user = (await DemoUsers().findById('1'))!;
  final tokens = await auth.createTokens(user);
  print(
    'token_type=${tokens.toJson()['token_type']} expires_in=${tokens.expiresIn}',
  );

  // Protect routes with middleware; requireRole() requires any listed role.
  final app = App(
    config: const AppConfig(environment: AppEnvironment.testing),
    logger: Logger(level: LogLevel.fatal, handlers: []),
  );
  app.get(
    '/admin',
    (request) => Response.ok({'ok': true}),
    middleware: [
      auth.middleware(),
      auth.requireRole(['admin']),
    ],
  );

  final anonymous = await app.send('GET', '/admin');
  print('GET /admin without token -> ${anonymous.statusCode}');
  final authed = await app.send(
    'GET',
    '/admin',
    headers: {'authorization': 'Bearer ${tokens.accessToken}'},
  );
  print('GET /admin with token    -> ${authed.statusCode}');

  // Refresh rotates the token; replaying the old one revokes the whole chain.
  final next = await auth.refresh(tokens.refreshToken);
  print('refreshed: ${next.refreshToken != tokens.refreshToken}');
  try {
    await auth.refresh(tokens.refreshToken);
  } on AuthenticationException {
    print('replayed refresh token -> AuthenticationException');
  }

  await DB.reset();
}
