import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:test/test.dart';

App newApp({
  AppConfig config = const AppConfig(environment: AppEnvironment.testing),
}) => App(
  config: config,
  logger: Logger(level: LogLevel.fatal, handlers: []),
);

Future<Map<String, dynamic>> j(Response r) async =>
    (await r.readJson()) as Map<String, dynamic>;

void main() {
  group('routing', () {
    test('all HTTP methods, params and query', () async {
      final app = newApp();
      app.get(
        '/users/:id',
        (r) => Response.ok({'id': r.param('id'), 'q': r.query('q')}),
      );
      app.post('/users', (r) async => Response.created(await r.json()));
      app.put('/users/:id', (r) => Response.ok({'m': r.method}));
      app.patch('/users/:id', (r) => Response.ok({'m': r.method}));
      app.delete('/users/:id', (r) => Response.noContent());
      app.options('/users', (r) => Response(204, headers: {'x-custom': '1'}));
      app.head('/users', (r) => Response(200, headers: {'x-count': '3'}));

      var res = await app.send('GET', '/users/42?q=hi');
      expect(res.statusCode, 200);
      expect(await j(res), {'id': '42', 'q': 'hi'});
      res = await app.send('POST', '/users', body: {'name': 'x'});
      expect(res.statusCode, 201);
      expect(await j(res), {'name': 'x'});
      expect((await j(await app.send('PUT', '/users/1'))), {'m': 'PUT'});
      expect((await j(await app.send('PATCH', '/users/1'))), {'m': 'PATCH'});
      expect((await app.send('DELETE', '/users/1')).statusCode, 204);
      expect((await app.send('OPTIONS', '/users')).header('x-custom'), '1');
      expect((await app.send('HEAD', '/users')).header('x-count'), '3');
    });

    test('percent-decoding, trailing slash, wildcard', () async {
      final app = newApp();
      app.get('/files/*', (r) => Response.ok({'p': r.param('*')}));
      app.get('/n/:name', (r) => Response.ok({'n': r.param('name')}));
      expect((await j(await app.send('GET', '/n/a%20b/')))['n'], 'a b');
      expect(
        (await j(await app.send('GET', '/files/a/b/c.txt')))['p'],
        'a/b/c.txt',
      );
      // Dart's Uri normalises malformed escapes to a literal '%', never a crash.
      expect((await j(await app.send('GET', '/n/%ZZ')))['n'], '%ZZ');
    });

    test('404 and 405 with Allow header; automatic OPTIONS', () async {
      final app = newApp();
      app.get('/a', (r) => Response.ok('x'));
      app.post('/a', (r) => Response.ok('x'));
      final nf = await app.send('GET', '/nope');
      expect(nf.statusCode, 404);
      expect((await j(nf))['success'], false);
      final na = await app.send('DELETE', '/a');
      expect(na.statusCode, 405);
      expect(na.header('allow'), 'GET, POST');
      expect((await app.send('OPTIONS', '/a')).statusCode, 204);
    });

    test('groups, prefixes, nested groups, named routes', () async {
      final app = newApp();
      final order = <String>[];
      Middleware tag(String n) => Middleware.from((r, next) {
        order.add(n);
        return next(r);
      });
      app.use(tag('global'));
      app.group(
        '/api',
        middleware: [tag('api')],
        routes: () {
          app.group(
            '/admin',
            middleware: [tag('admin')],
            routes: () {
              app.get(
                '/dash',
                (r) => Response.ok({'ok': true}),
                middleware: [tag('route')],
                name: 'admin.dash',
              );
            },
          );
          app.get('/users/:id', (r) => Response.ok({}), name: 'users.show');
        },
      );
      expect((await app.send('GET', '/api/admin/dash')).statusCode, 200);
      expect(order, ['global', 'api', 'admin', 'route']);
      expect(app.url('users.show', {'id': 'a b'}), '/api/users/a%20b');
      expect(() => app.url('nope'), throwsArgumentError);
      expect(
        () => app.get(
          '/api/users/:id',
          (r) => Response.ok('x'),
          name: 'users.show',
        ),
        throwsStateError,
      );
    });

    test('duplicate routes are rejected', () {
      final app = newApp();
      app.get('/x', (r) => Response.ok('a'));
      expect(() => app.get('/x/', (r) => Response.ok('b')), throwsStateError);
    });

    test('route timeout yields 504', () async {
      final app = newApp();
      app.get('/slow', (r) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return Response.ok('x');
      }, timeout: const Duration(milliseconds: 20));
      expect((await app.send('GET', '/slow')).statusCode, 504);
    });
  });

  group('request', () {
    test('json, form, text, body(), headers, cookies', () async {
      final app = newApp();
      app.post(
        '/echo',
        (r) async => Response.ok({
          'body': await r.body(),
          'auth': r.header('Authorization'),
          'cookie': r.cookie('sid'),
          'path': r.path,
        }),
      );
      var res = await app.send(
        'POST',
        '/echo',
        body: {'a': 1},
        headers: {'authorization': 'Bearer t', 'cookie': 'x=1; sid=a%20b'},
      );
      var data = await j(res);
      expect(data['body'], {'a': 1});
      expect(data['auth'], 'Bearer t');
      expect(data['cookie'], 'a b');
      res = await app.send(
        'POST',
        '/echo',
        body: 'a=1&b=two',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      expect((await j(res))['body'], {'a': '1', 'b': 'two'});
    });

    test(
      'send() treats Uint8List as raw bytes and List<int> as a JSON array',
      () async {
        final app = newApp();
        app.post(
          '/raw',
          (r) async => Response.ok({
            'len': (await r.bytes()).length,
            'type': r.contentType,
          }),
        );
        app.post('/arr', (r) async => Response.ok({'v': await r.jsonAny()}));
        final raw = await app.send(
          'POST',
          '/raw',
          body: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 255]),
          headers: {'content-type': 'image/png'},
        );
        expect(await j(raw), {'len': 6, 'type': 'image/png'});
        expect(await j(await app.send('POST', '/arr', body: [1, 2, 3])), {
          'v': [1, 2, 3],
        });
      },
    );

    test(
      'malformed JSON -> 400, non-object -> 400, unsupported type -> 415',
      () async {
        final app = newApp();
        app.post('/j', (r) async => Response.ok(await r.json()));
        app.post('/b', (r) async => Response.ok(await r.body()));
        expect(
          (await app.send(
            'POST',
            '/j',
            body: '{bad',
            headers: {'content-type': 'application/json'},
          )).statusCode,
          400,
        );
        expect(
          (await app.send(
            'POST',
            '/j',
            body: '[1]',
            headers: {'content-type': 'application/json'},
          )).statusCode,
          400,
        );
        expect((await app.send('POST', '/j')).statusCode, 400);
        expect(
          (await app.send(
            'POST',
            '/b',
            body: 'x',
            headers: {'content-type': 'text/weird'},
          )).statusCode,
          415,
        );
      },
    );

    test(
      'body can be read repeatedly (buffered once) and is size limited',
      () async {
        final app = newApp(
          config: const AppConfig(
            environment: AppEnvironment.testing,
            limits: BodyLimits(maxBodyBytes: 20),
          ),
        );
        app.post('/twice', (r) async {
          final a = await r.text();
          final b = await r.text();
          return Response.ok({'same': a == b, 'len': a.length});
        });
        expect(
          (await j(await app.send('POST', '/twice', body: 'hello')))['same'],
          true,
        );
        final big = await app.send('POST', '/twice', body: 'x' * 100);
        expect(big.statusCode, 413);
      },
    );

    test('multipart uploads parse fields and files with sanitized names', () async {
      final app = newApp();
      app.post('/up', (r) async {
        final m = await r.multipart();
        return Response.ok({
          'fields': m.fields,
          'files': [
            for (final f in m.files)
              {
                'field': f.field,
                'name': f.filename,
                'size': f.size,
                'type': f.contentType,
                'ext': f.extension,
              },
          ],
        });
      });
      const b = 'XBOUNDARYX';
      final payload =
          '--$b\r\nContent-Disposition: form-data; name="title"\r\n\r\nHello\r\n'
          '--$b\r\nContent-Disposition: form-data; name="doc"; filename="../../etc/passwd.TXT"\r\n'
          'Content-Type: text/plain\r\n\r\nfile-bytes\r\n--$b--\r\n';
      final res = await app.send(
        'POST',
        '/up',
        body: payload,
        headers: {'content-type': 'multipart/form-data; boundary=$b'},
      );
      final d = await j(res);
      expect(d['fields'], {'title': 'Hello'});
      final f = (d['files'] as List).single as Map;
      expect(f['name'], 'passwd.TXT');
      expect(f['size'], 10);
      expect(f['ext'], 'txt');
      expect(f['type'], 'text/plain');
    });

    test('ip ignores X-Forwarded-For unless trustProxy', () async {
      for (final trust in [false, true]) {
        final app = newApp(
          config: AppConfig(
            environment: AppEnvironment.testing,
            trustProxy: trust,
          ),
        );
        app.get('/ip', (r) => Response.ok({'ip': r.ip}));
        final d = await j(
          await app.send(
            'GET',
            '/ip',
            headers: {'x-forwarded-for': '9.9.9.9, 1.1.1.1'},
          ),
        );
        expect(d['ip'], trust ? '9.9.9.9' : 'unknown');
      }
    });
  });

  group('response helpers', () {
    test('envelopes and status codes', () async {
      expect((await j(Response.success([1], message: 'ok', meta: {'p': 1}))), {
        'success': true,
        'message': 'ok',
        'data': [1],
        'meta': {'p': 1},
      });
      final nf = Response.notFound('User not found');
      expect(nf.statusCode, 404);
      expect(await j(nf), {'success': false, 'message': 'User not found'});
      expect(await j(Response.notFound({'message': 'custom'})), {
        'message': 'custom',
      });
      final v = Response.validationError({
        'email': ['Email is required'],
      });
      expect(v.statusCode, 422);
      expect(await j(v), {
        'success': false,
        'message': 'Validation failed',
        'errors': {
          'email': ['Email is required'],
        },
      });
      for (final (r, c) in [
        (Response.badRequest(), 400),
        (Response.unauthorized(), 401),
        (Response.forbidden(), 403),
        (Response.serverError(), 500),
        (Response.created({}), 201),
        (Response.noContent(), 204),
      ]) {
        expect(r.statusCode, c);
      }
    });

    test('json encodes DateTime and toJson objects', () async {
      final r = Response.ok({'t': DateTime.utc(2025, 1, 1), 'o': _Pt(1, 2)});
      expect(await j(r), {
        't': '2025-01-01T00:00:00.000Z',
        'o': {'x': 1, 'y': 2},
      });
    });

    test('text, html, redirect, download, cookies', () async {
      expect(
        Response.text('hi').header('content-type'),
        contains('text/plain'),
      );
      expect(
        Response.html('<b/>').header('content-type'),
        contains('text/html'),
      );
      expect(Response.redirect('/x').statusCode, 302);
      expect(Response.redirect('/x').header('location'), '/x');
      final d = Response.download([1, 2], 'a"b\n.txt');
      expect(d.header('content-disposition'), isNot(contains('\n')));
      final c = Response.ok(
        {},
      ).cookie('sid', 'v', maxAge: const Duration(hours: 1));
      expect(
        c.headers['set-cookie']!.single,
        allOf(
          contains('HttpOnly'),
          contains('Secure'),
          contains('SameSite=Lax'),
          contains('Max-Age=3600'),
        ),
      );
      expect(() => Response.ok({}).cookie('a b', 'v'), throwsArgumentError);
      expect(() => Response.ok({}).cookie('a', 'v;x'), throwsArgumentError);
    });

    test('streaming response', () async {
      final r = Response.stream(
        Stream.fromIterable([utf8.encode('a'), utf8.encode('b')]),
        contentType: 'text/plain',
      );
      expect(await r.readText(), 'ab');
    });
  });

  group('error handling', () {
    test(
      'exceptions map to statuses; 500 hides internals in production',
      () async {
        final app = newApp(
          config: const AppConfig(environment: AppEnvironment.production),
        );
        app.get(
          '/v',
          (r) => throw ValidationException({
            'a': ['bad'],
          }),
        );
        app.get('/n', (r) => throw NotFoundException('nope'));
        app.get('/a', (r) => throw AuthenticationException());
        app.get('/f', (r) => throw AuthorizationException());
        app.get(
          '/db',
          (r) => throw QueryException(
            'SELECT secret FROM x',
            sql: 'SELECT secret FROM x',
          ),
        );
        app.get('/boom', (r) => throw StateError('password=hunter2'));
        expect((await app.send('GET', '/v')).statusCode, 422);
        expect((await app.send('GET', '/n')).statusCode, 404);
        expect((await app.send('GET', '/a')).statusCode, 401);
        expect((await app.send('GET', '/f')).statusCode, 403);
        for (final p in ['/db', '/boom']) {
          final r = await app.send('GET', p);
          expect(r.statusCode, 500);
          final text = await r.readText();
          expect(text, isNot(contains('hunter2')));
          expect(text, isNot(contains('secret')));
          expect(text, isNot(contains('stack')));
          expect(jsonDecode(text)['message'], 'Internal server error');
        }
      },
    );

    test('exception details and hint never reach HTTP responses', () async {
      for (final env in [AppEnvironment.production, AppEnvironment.testing]) {
        final app = newApp(config: AppConfig(environment: env));
        app.get(
          '/q',
          (r) => throw QueryException(
            'Database query failed (42P07).',
            details: 'relation "users" already exists; table: users',
            hint: 'migrations may have run partially',
          ),
        );
        app.get(
          '/c',
          (r) => throw ConnectionException(
            'Could not connect.',
            details: 'password authentication failed for user "dbuser"',
            hint: 'Check DB_PASSWORD',
          ),
        );
        for (final p in ['/q', '/c']) {
          final res = await app.send('GET', p);
          expect(res.statusCode, 500);
          final text = await res.readText();
          expect(text, isNot(contains('already exists')));
          expect(text, isNot(contains('dbuser')));
          expect(text, isNot(contains('migrations')));
          expect(text, isNot(contains('DB_PASSWORD')));
          expect(text, isNot(contains('Details:')));
          expect(jsonDecode(text)['message'], 'Internal server error');
        }
      }
    });

    test('debug mode exposes details only in development', () async {
      final app = newApp(
        config: const AppConfig(environment: AppEnvironment.development),
      );
      app.get('/boom', (r) => throw StateError('visible'));
      expect(
        await (await app.send('GET', '/boom')).readText(),
        contains('visible'),
      );
    });
  });

  group('built-in middleware', () {
    test('request id, timing, security headers', () async {
      final app = newApp();
      app.use(const TimingMiddleware());
      app.use(const SecurityHeadersMiddleware());
      app.get('/x', (r) => Response.ok({'rid': r.attributes['request_id']}));
      final res = await app.send(
        'GET',
        '/x',
        headers: {'x-request-id': 'abc-12345678'},
      );
      expect(res.header('x-request-id'), 'abc-12345678');
      expect(res.header('x-response-time'), endsWith('ms'));
      expect(res.header('x-content-type-options'), 'nosniff');
      final bad = await app.send(
        'GET',
        '/x',
        headers: {'x-request-id': 'bad id\r\n'},
      );
      expect(bad.header('x-request-id'), matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('CORS: simple, preflight, credentials guard', () async {
      final app = newApp();
      app.use(
        CorsMiddleware(
          allowedOrigins: ['https://a.com'],
          allowCredentials: true,
        ),
      );
      app.get('/x', (r) => Response.ok('x'));
      final simple = await app.send(
        'GET',
        '/x',
        headers: {'origin': 'https://a.com'},
      );
      expect(simple.header('access-control-allow-origin'), 'https://a.com');
      expect(simple.header('vary'), 'Origin');
      final denied = await app.send(
        'GET',
        '/x',
        headers: {'origin': 'https://evil.com'},
      );
      expect(denied.header('access-control-allow-origin'), isNull);
      final pre = await app.send(
        'OPTIONS',
        '/x',
        headers: {
          'origin': 'https://a.com',
          'access-control-request-method': 'POST',
        },
      );
      expect(pre.statusCode, 204);
      expect(pre.header('access-control-allow-methods'), contains('POST'));
      expect(() => CorsMiddleware(allowCredentials: true), throwsArgumentError);
    });

    test('rate limiting with window reset', () async {
      var now = DateTime(2025);
      final app = newApp();
      app.use(
        RateLimitMiddleware(
          maxRequests: 2,
          duration: const Duration(minutes: 1),
          clock: () => now,
        ),
      );
      app.get('/x', (r) => Response.ok('x'));
      expect((await app.send('GET', '/x')).statusCode, 200);
      final second = await app.send('GET', '/x');
      expect(second.statusCode, 200);
      expect(second.header('x-ratelimit-remaining'), '0');
      final third = await app.send('GET', '/x');
      expect(third.statusCode, 429);
      expect(third.header('retry-after'), isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect((await app.send('GET', '/x')).statusCode, 200);
    });

    test('maintenance mode and compression', () async {
      var down = true;
      final app = newApp();
      app.use(MaintenanceMiddleware(() => down));
      app.use(const CompressionMiddleware(minBytes: 10));
      app.get('/x', (r) => Response.ok({'data': 'y' * 500}));
      app.get('/health', (r) => Response.ok({'up': true}));
      expect((await app.send('GET', '/x')).statusCode, 503);
      expect((await app.send('GET', '/health')).statusCode, 200);
      down = false;
      final gz = await app.send(
        'GET',
        '/x',
        headers: {'accept-encoding': 'gzip'},
      );
      expect(gz.header('content-encoding'), 'gzip');
      expect(
        jsonDecode(utf8.decode(gzip.decode(await gz.readBytes())))['data'],
        hasLength(500),
      );
      expect((await app.send('GET', '/x')).header('content-encoding'), isNull);
    });

    test('logger redacts and logs path only', () async {
      final mem = MemoryHandler();
      final app = App(
        config: const AppConfig(environment: AppEnvironment.testing),
        logger: Logger(handlers: [mem]),
      );
      app.get('/x', (r) => Response.ok('x'));
      await app.send('GET', '/x?token=secret123');
      final line = mem.records.map((r) => r.message).join();
      expect(line, contains('GET /x 200'));
      expect(line, isNot(contains('secret123')));
      expect(mem.records.first.requestId, isNotNull);
    });
  });

  group('observers', () {
    test(
      'receive route pattern (not the raw path), status, duration, request id and errors',
      () async {
        final app = newApp();
        final seen = <RequestRecord>[];
        app.observe(seen.add);
        app.get('/users/:id', (r) => Response.ok({'id': r.param('id')}));
        app.get('/boom', (r) => throw StateError('kaput'));
        await app.send('GET', '/users/42?token=secret');
        await app.send('GET', '/boom');
        await app.send('GET', '/nope');
        await app.send('POST', '/users/42');
        expect(seen.map((r) => r.status), [200, 500, 404, 405]);
        expect(seen[0].route, '/users/:id');
        expect(
          seen[0].path,
          '/users/42',
          reason: 'the query string (often tokens) is never recorded',
        );
        expect(seen[0].requestId, isNotNull);
        expect(seen[0].duration, isA<Duration>());
        expect(seen[1].route, '/boom');
        expect(seen[1].error, isA<StateError>());
        expect(seen[1].stackTrace, isNotNull);
        expect(seen[2].route, isNull);
        expect(seen[3].route, isNull);
      },
    );

    test(
      'a throwing observer cannot break request handling; no observers means no overhead path',
      () async {
        final app = newApp();
        app.observe((_) => throw StateError('bad observer'));
        app.get('/x', (r) => Response.ok('x'));
        expect((await app.send('GET', '/x')).statusCode, 200);
        final plain = newApp()..get('/x', (r) => Response.ok('x'));
        expect((await plain.send('GET', '/x')).statusCode, 200);
      },
    );
  });

  group('real server', () {
    test('serves over HTTP and shuts down gracefully', () async {
      final app = newApp();
      app.get('/hello', (r) => Response.ok({'hello': 'world'}));
      app.get('/slow', (r) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return Response.ok({'done': true});
      });
      var hookRan = false;
      app.onShutdown(() async => hookRan = true);
      await app.start(port: 0, handleSignals: false);
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${app.port}/hello'),
      );
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(jsonDecode(await utf8.decodeStream(res)), {'hello': 'world'});

      // an in-flight request survives shutdown
      final slowReq = await client.getUrl(
        Uri.parse('http://127.0.0.1:${app.port}/slow'),
      );
      final slowFuture = slowReq.close().then(utf8.decodeStream);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await app.stop();
      expect(jsonDecode(await slowFuture), {'done': true});
      expect(hookRan, isTrue);
      client.close(force: true);
    });
  });
}

class _Pt {
  _Pt(this.x, this.y);
  final int x, y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
}
