import 'dart:convert';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

const secret = 'test-secret-test-secret-test-secret-0123456789';

class Users implements UserRepository {
  final Map<String, AuthUser> byId = {
    '1': const AuthUser(
      id: 1,
      email: 'a@x.io',
      roles: ['admin'],
      permissions: ['posts.*'],
    ),
    '2': const AuthUser(
      id: 2,
      email: 'b@x.io',
      roles: ['user'],
      permissions: ['posts.read'],
    ),
  };
  @override
  Future<AuthUser?> findById(String id) async => byId[id];
}

// Cheap parameters keep the suite fast; one test checks the production defaults.
Argon2idHasher fastHasher() => Argon2idHasher(memoryKiB: 64, iterations: 1);

AuthService newService({AuthStores? stores, Users? users}) => AuthService(
  secret: secret,
  hasher: fastHasher(),
  users: users ?? Users(),
  stores: stores,
);

App newApp() => App(
  config: const AppConfig(environment: AppEnvironment.testing),
  logger: Logger(level: LogLevel.fatal, handlers: []),
);

Map<String, String> bearer(String t) => {'authorization': 'Bearer $t'};

void main() {
  group('passwords', () {
    test(
      'hash/verify with PHC format, unique salts, wrong password fails',
      () async {
        final h = fastHasher();
        final a = await h.hash('correct horse');
        final b = await h.hash('correct horse');
        expect(a, startsWith(r'$argon2id$v=19$m=64,t=1,p=1$'));
        expect(a, isNot(b));
        expect(await h.verify('correct horse', a), isTrue);
        expect(await h.verify('wrong', a), isFalse);
        expect(await h.verify('x', 'garbage'), isFalse);
        expect(
          await h.verify('x', r'$argon2id$v=19$m=99999999,t=2,p=1$AAAA$AAAA'),
          isFalse,
          reason: 'absurd cost parameters are refused',
        );
        expect(h.needsRehash(a), isFalse);
        expect(
          Argon2idHasher(memoryKiB: 128, iterations: 1).needsRehash(a),
          isTrue,
        );
      },
    );

    test(
      'production defaults (OWASP minimum) work and finish in reasonable time',
      () async {
        final h = Argon2idHasher();
        final sw = Stopwatch()..start();
        final hash = await h.hash('pw');
        expect(await h.verify('pw', hash), isTrue);
        printOnFailure(
          'argon2id default hash+verify: ${sw.elapsedMilliseconds}ms',
        );
        expect(hash, contains('m=19456,t=2,p=1'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('JWT', () {
    test('weak/short secrets are rejected at construction', () {
      expect(
        () => AuthService(secret: 'short'),
        throwsA(isA<ConfigurationException>()),
      );
      expect(
        () => AuthService(secret: 'replace_me'),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('issue and verify; claims carry roles', () async {
      final auth = newService();
      final pair = await auth.createTokens((await Users().findById('1'))!);
      final claims = await auth.verifyAccessToken(pair.accessToken);
      expect(claims.subject, '1');
      expect(claims.roles, ['admin']);
      expect(pair.expiresIn, 900);
      expect(pair.refreshToken, startsWith('rt_'));
      expect(pair.toJson()['token_type'], 'Bearer');
    });

    test(
      'expired, tampered, wrong-issuer/audience tokens are rejected',
      () async {
        final auth = newService();
        final user = (await Users().findById('1'))!;
        final expired = await auth.createTokens(
          user,
          accessTtl: const Duration(seconds: -10),
        );
        await expectLater(
          auth.verifyAccessToken(expired.accessToken),
          throwsA(isA<AuthenticationException>()),
        );

        final good = (await auth.createTokens(user)).accessToken;
        final parts = good.split('.');
        final tampered =
            '${parts[0]}.${base64Url.encode(utf8.encode(jsonEncode({
              'sub': '1',
              'roles': ['root'],
              'jti': 'x',
              'exp': 9999999999,
              'iss': 'dartcore',
              'aud': 'dartcore-api',
            }))).replaceAll('=', '')}.${parts[2]}';
        await expectLater(
          auth.verifyAccessToken(tampered),
          throwsA(isA<AuthenticationException>()),
        );

        final other = AuthService(
          secret: secret,
          issuer: 'evil',
          hasher: fastHasher(),
        );
        final foreign = (await other.createTokens(user)).accessToken;
        await expectLater(
          auth.verifyAccessToken(foreign),
          throwsA(isA<AuthenticationException>()),
        );
        final otherSecret = AuthService(
          secret: '${secret}X',
          hasher: fastHasher(),
        );
        await expectLater(
          auth.verifyAccessToken(
            (await otherSecret.createTokens(user)).accessToken,
          ),
          throwsA(isA<AuthenticationException>()),
        );
      },
    );

    test('alg:none and non-HS256 tokens are rejected', () async {
      final auth = newService();
      String b64(Object o) =>
          base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
      final payload = b64({
        'sub': '1',
        'jti': 'j',
        'exp': 9999999999,
        'iss': 'dartcore',
        'aud': 'dartcore-api',
      });
      for (final alg in ['none', 'None', 'HS512', 'RS256']) {
        final t = '${b64({'alg': alg, 'typ': 'JWT'})}.$payload.';
        await expectLater(
          auth.verifyAccessToken(t),
          throwsA(isA<AuthenticationException>()),
          reason: alg,
        );
      }
      await expectLater(
        auth.verifyAccessToken('garbage'),
        throwsA(isA<AuthenticationException>()),
      );
      await expectLater(
        auth.verifyAccessToken('a.b.c'),
        throwsA(isA<AuthenticationException>()),
      );
    });
  });

  group('refresh tokens', () {
    test('rotation: new pair works, old token is single-use', () async {
      final auth = newService();
      final p1 = await auth.createTokens((await Users().findById('1'))!);
      final p2 = await auth.refresh(p1.refreshToken);
      expect(p2.refreshToken, isNot(p1.refreshToken));
      await auth.verifyAccessToken(p2.accessToken);
      final p3 = await auth.refresh(p2.refreshToken);
      expect(p3.refreshToken, isNotNull);
    });

    test('replaying a used refresh token revokes the entire family', () async {
      final auth = newService();
      final p1 = await auth.createTokens((await Users().findById('1'))!);
      final p2 = await auth.refresh(p1.refreshToken);
      await expectLater(
        auth.refresh(p1.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
      // attacker replay also kills the legitimate descendant
      await expectLater(
        auth.refresh(p2.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('unknown, expired tokens and deleted users fail', () async {
      final users = Users();
      final auth = AuthService(
        secret: secret,
        hasher: fastHasher(),
        users: users,
        refreshTtl: const Duration(milliseconds: -1),
      );
      await expectLater(
        auth.refresh('rt_nope'),
        throwsA(isA<AuthenticationException>()),
      );
      final p = await auth.createTokens((await users.findById('1'))!);
      await expectLater(
        auth.refresh(p.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
      final auth2 = newService(users: users);
      final p2 = await auth2.createTokens((await users.findById('2'))!);
      users.byId.remove('2');
      await expectLater(
        auth2.refresh(p2.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('only hashes are stored', () async {
      final stores = AuthStores.memory();
      final auth = newService(stores: stores);
      final p = await auth.createTokens((await Users().findById('1'))!);
      expect(await stores.refreshTokens.findByHash(p.refreshToken), isNull);
      expect(
        await stores.refreshTokens.findByHash(
          AuthService.hashToken(p.refreshToken),
        ),
        isNotNull,
      );
    });
  });

  group('HTTP integration', () {
    late AuthService auth;
    late App app;
    setUp(() {
      auth = newService();
      app = newApp();
      app.get('/public', (r) => Response.ok({'public': true}));
      app.group(
        '/admin',
        middleware: [
          auth.middleware(),
          auth.requireRole(['admin']),
        ],
        routes: () {
          app.get('/dashboard', (r) async {
            final u = await auth.authenticate(r);
            return Response.ok({'user': u!.id});
          });
        },
      );
      app.get(
        '/posts',
        (r) => Response.ok({'ok': true}),
        middleware: [
          auth.middleware(),
          auth.requirePermission(['posts.read']),
        ],
      );
      app.delete(
        '/posts/1',
        (r) => Response.ok({'ok': true}),
        middleware: [
          auth.middleware(),
          auth.requirePermission(['posts.delete']),
        ],
      );
      app.get(
        '/maybe',
        (r) async => Response.ok({'user': (await auth.authenticate(r))?.id}),
        middleware: [auth.middleware(optional: true)],
      );
    });

    test('401 without/invalid token, 403 wrong role, 200 admin', () async {
      expect((await app.send('GET', '/public')).statusCode, 200);
      final none = await app.send('GET', '/admin/dashboard');
      expect(none.statusCode, 401);
      expect(none.header('www-authenticate'), 'Bearer');
      expect(
        (await app.send(
          'GET',
          '/admin/dashboard',
          headers: bearer('junk'),
        )).statusCode,
        401,
      );
      final user = await auth.createTokens((await Users().findById('2'))!);
      expect(
        (await app.send(
          'GET',
          '/admin/dashboard',
          headers: bearer(user.accessToken),
        )).statusCode,
        403,
      );
      final admin = await auth.createTokens((await Users().findById('1'))!);
      final ok = await app.send(
        'GET',
        '/admin/dashboard',
        headers: bearer(admin.accessToken),
      );
      expect(ok.statusCode, 200);
      expect(await ok.readJson(), {'user': 1});
    });

    test('permissions incl. wildcards; optional auth', () async {
      final admin = (await auth.createTokens(
        (await Users().findById('1'))!,
      )).accessToken;
      final user = (await auth.createTokens(
        (await Users().findById('2'))!,
      )).accessToken;
      expect(
        (await app.send(
          'DELETE',
          '/posts/1',
          headers: bearer(admin),
        )).statusCode,
        200,
        reason: 'posts.* wildcard',
      );
      expect(
        (await app.send(
          'DELETE',
          '/posts/1',
          headers: bearer(user),
        )).statusCode,
        403,
      );
      expect(
        (await app.send('GET', '/posts', headers: bearer(user))).statusCode,
        200,
      );
      expect(await (await app.send('GET', '/maybe')).readJson(), {
        'user': null,
      });
      expect(
        await (await app.send(
          'GET',
          '/maybe',
          headers: bearer(user),
        )).readJson(),
        {'user': 2},
      );
      expect(
        (await app.send('GET', '/maybe', headers: bearer('bad'))).statusCode,
        401,
      );
    });

    test('logout revokes the token immediately', () async {
      final pair = await auth.createTokens((await Users().findById('1'))!);
      app.post('/logout', (r) async {
        await auth.logout(r, refreshToken: r.header('x-refresh'));
        return Response.ok({'bye': true});
      }, middleware: [auth.middleware()]);
      expect(
        (await app.send(
          'GET',
          '/admin/dashboard',
          headers: bearer(pair.accessToken),
        )).statusCode,
        200,
      );
      expect(
        (await app.send(
          'POST',
          '/logout',
          headers: {
            ...bearer(pair.accessToken),
            'x-refresh': pair.refreshToken,
          },
        )).statusCode,
        200,
      );
      expect(
        (await app.send(
          'GET',
          '/admin/dashboard',
          headers: bearer(pair.accessToken),
        )).statusCode,
        401,
      );
      await expectLater(
        auth.refresh(pair.refreshToken),
        throwsA(isA<AuthenticationException>()),
        reason: 'logout also revokes the refresh family',
      );
    });

    test(
      'fresh roles come from the repository, not stale token claims',
      () async {
        final users = Users();
        final a = newService(users: users);
        final ap = newApp()
          ..get(
            '/x',
            (r) => Response.ok({}),
            middleware: [
              a.middleware(),
              a.requireRole(['admin']),
            ],
          );
        final token = (await a.createTokens(
          (await users.findById('1'))!,
        )).accessToken;
        expect(
          (await ap.send('GET', '/x', headers: bearer(token))).statusCode,
          200,
        );
        users.byId['1'] = const AuthUser(id: 1, roles: ['user']); // demoted
        expect(
          (await ap.send('GET', '/x', headers: bearer(token))).statusCode,
          403,
        );
      },
    );

    test(
      'API tokens: header auth, abilities, expiry, revocation, hashed at rest',
      () async {
        final stores = AuthStores.memory();
        final a = newService(stores: stores);
        final ap = newApp()
          ..get(
            '/data',
            (r) => Response.ok({'ok': true}),
            middleware: [
              a.middleware(),
              a.requirePermission(['read:data']),
            ],
          );
        final plain = await a.createApiToken(
          '2',
          'ci',
          abilities: ['read:data'],
        );
        expect(plain, startsWith('dc_'));
        expect(
          await stores.apiTokens.findByHash(plain),
          isNull,
          reason: 'plaintext never stored',
        );
        expect(
          (await ap.send(
            'GET',
            '/data',
            headers: {'x-api-key': plain},
          )).statusCode,
          200,
        );
        expect(
          (await ap.send('GET', '/data', headers: bearer(plain))).statusCode,
          200,
        );
        expect(
          (await ap.send(
            'GET',
            '/data',
            headers: {'x-api-key': 'dc_forged'},
          )).statusCode,
          401,
        );
        final narrow = await a.createApiToken(
          '2',
          'narrow',
          abilities: ['other'],
        );
        expect(
          (await ap.send(
            'GET',
            '/data',
            headers: {'x-api-key': narrow},
          )).statusCode,
          403,
        );
        final expired = await a.createApiToken(
          '2',
          'old',
          abilities: ['read:data'],
          ttl: const Duration(milliseconds: -1),
        );
        expect(
          (await ap.send(
            'GET',
            '/data',
            headers: {'x-api-key': expired},
          )).statusCode,
          401,
        );
        await a.revokeApiToken(plain);
        expect(
          (await ap.send(
            'GET',
            '/data',
            headers: {'x-api-key': plain},
          )).statusCode,
          401,
        );
      },
    );

    test('cookie auth and secure cookie attributes', () async {
      final pair = await auth.createTokens((await Users().findById('1'))!);
      final res = auth.withTokenCookies(Response.ok({}), pair);
      final cookies = res.headers['set-cookie']!;
      expect(cookies, hasLength(2));
      for (final c in cookies) {
        expect(
          c,
          allOf(
            contains('HttpOnly'),
            contains('Secure'),
            contains('SameSite=Strict'),
          ),
        );
      }
      final ap = newApp()
        ..get(
          '/c',
          (r) => Response.ok({}),
          middleware: [auth.middleware(cookieName: 'access_token')],
        );
      expect(
        (await ap.send(
          'GET',
          '/c',
          headers: {'cookie': 'access_token=${pair.accessToken}'},
        )).statusCode,
        200,
      );
      expect((await ap.send('GET', '/c')).statusCode, 401);
    });
  });

  group('password reset tokens', () {
    test('single use, expiry, case-insensitive email, wrong token', () async {
      final auth = newService();
      final t = await auth.createPasswordResetToken('User@X.io');
      expect(
        await auth.consumePasswordResetToken('user@x.io', 'wrong'),
        isFalse,
      );
      expect(await auth.consumePasswordResetToken('user@x.io', t), isTrue);
      expect(
        await auth.consumePasswordResetToken('user@x.io', t),
        isFalse,
        reason: 'single use',
      );
      final old = await auth.createPasswordResetToken(
        'a@x.io',
        ttl: const Duration(milliseconds: -1),
      );
      expect(await auth.consumePasswordResetToken('a@x.io', old), isFalse);
      expect(await auth.consumePasswordResetToken('nobody@x.io', 'x'), isFalse);
    });
  });

  group('sessions', () {
    test('start, current, sliding expiry, destroy', () async {
      final s = SessionManager(
        secureCookie: false,
        ttl: const Duration(minutes: 5),
      );
      final res = s.start(Response.ok({}), '42', data: {'cart': 1});
      final cookie = res.headers['set-cookie']!.single.split(';').first;
      final app = newApp()
        ..get('/me', (r) => Response.ok({'u': s.current(r)?.userId}))
        ..post('/logout', (r) => s.destroy(r, Response.ok({})));
      expect(
        await (await app.send(
          'GET',
          '/me',
          headers: {'cookie': cookie},
        )).readJson(),
        {'u': '42'},
      );
      expect(
        await (await app.send(
          'GET',
          '/me',
          headers: {'cookie': 'dartcore_session=forged'},
        )).readJson(),
        {'u': null},
      );
      await app.send('POST', '/logout', headers: {'cookie': cookie});
      expect(
        await (await app.send(
          'GET',
          '/me',
          headers: {'cookie': cookie},
        )).readJson(),
        {'u': null},
      );
    });
  });

  group('database stores', () {
    test('full flow persisted in SQLite incl. replay detection', () async {
      registerSqlite();
      final m = DatabaseManager();
      final db = await m.connect(
        const ConnectionConfig(
          driver: DatabaseDriver.sqlite,
          database: ':memory:',
        ),
      );
      await DatabaseAuthStores.createTables(db);
      await DatabaseAuthStores.createTables(db); // idempotent
      final auth = newService(stores: DatabaseAuthStores(db).stores);
      final user = (await Users().findById('1'))!;
      final p1 = await auth.createTokens(user);
      final p2 = await auth.refresh(p1.refreshToken);
      await expectLater(
        auth.refresh(p1.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
      await expectLater(
        auth.refresh(p2.refreshToken),
        throwsA(isA<AuthenticationException>()),
      );
      final p3 = await auth.createTokens(user);
      await auth.revoke(p3.accessToken);
      await expectLater(
        auth.verifyAccessToken(p3.accessToken),
        throwsA(isA<AuthenticationException>()),
      );
      final api = await auth.createApiToken(
        '1',
        'x',
        abilities: ['a', 'b'],
        ttl: const Duration(hours: 1),
      );
      expect(
        (await auth.stores.apiTokens.findByHash(
          AuthService.hashToken(api),
        ))!.abilities,
        ['a', 'b'],
      );
      final reset = await auth.createPasswordResetToken('a@x.io');
      expect(await auth.consumePasswordResetToken('a@x.io', reset), isTrue);
      expect(await auth.consumePasswordResetToken('a@x.io', reset), isFalse);
      await m.disconnect();
    });
  });

  test(
    'Auth facade middleware can be registered before Auth is configured',
    () async {
      Auth.reset();
      final app = newApp()
        ..get(
          '/p',
          (r) => Response.ok({}),
          middleware: [
            Auth.middleware(),
            Auth.role(['admin']),
          ],
        );
      expect(
        app.routes,
        hasLength(1),
      ); // building the route table must not throw
      Auth.configure(newService());
      final token = (await Auth.createToken(
        const AuthUser(id: 1, roles: ['admin']),
      )).accessToken;
      expect(
        (await app.send('GET', '/p', headers: bearer(token))).statusCode,
        200,
      );
      expect((await app.send('GET', '/p')).statusCode, 401);
      Auth.reset();
    },
  );

  test('Auth facade requires configuration', () {
    Auth.reset();
    expect(() => Auth.service, throwsA(isA<ConfigurationException>()));
    Auth.configure(newService());
    expect(Auth.service, isNotNull);
    Auth.reset();
  });
}
