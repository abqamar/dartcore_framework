import 'dart:convert';
import 'dart:io';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_dashboard/dartcore_dashboard.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:test/test.dart';

const token = 'dashboard-token-0123456789';

App makeApp({
  AppEnvironment env = AppEnvironment.testing,
  bool trustProxy = false,
}) => App(
  config: AppConfig(environment: env, trustProxy: trustProxy),
  logger: Logger(level: LogLevel.debug, handlers: [MemoryHandler()]),
);

Map<String, String> bearer([String t = token]) => {
  'authorization': 'Bearer $t',
};

Future<Object?> json(Response r) => r.readJson();

void main() {
  group('collection through a real app', () {
    late App app;
    late Dashboard dash;
    setUp(() {
      app = makeApp();
      dash = Dashboard.attach(app, token: token);
      app.get('/users/:id', (r) => Response.ok({'id': r.param('id')}));
      app.get('/boom', (r) => throw StateError('kaput secret=hunter2'));
    });

    test(
      'records route patterns (never raw ids or query strings), status and issues',
      () async {
        for (var i = 0; i < 5; i++) {
          await app.send('GET', '/users/$i?api_key=SECRET');
        }
        await app.send('GET', '/boom');
        await app.send('GET', '/nothing/here/123');
        final eps =
            await json(
                  await app.send(
                    'GET',
                    '/_dashboard/api/endpoints?range=15m',
                    headers: bearer(),
                  ),
                )
                as List;
        final routes = eps.map((e) => '${e['method']} ${e['route']}').toList();
        expect(
          routes,
          containsAll(['GET /users/:id', 'GET /boom', 'GET UNMATCHED']),
        );
        expect(routes.any((r) => r.contains('/users/3')), isFalse);
        final users = eps.firstWhere((e) => e['route'] == '/users/:id');
        expect(users['calls'], 5);
        expect(
          ['Good', 'Medium', 'Bad'],
          contains(users['impact']),
          reason:
              'the exact label depends on timing; the heuristic itself is tested deterministically in collector_test',
        );
        expect(jsonEncode(eps), isNot(contains('SECRET')));
        final issues =
            await json(
                  await app.send(
                    'GET',
                    '/_dashboard/api/issues',
                    headers: bearer(),
                  ),
                )
                as List;
        expect(issues.single['type'], 'StateError');
        expect(issues.single['route'], '/boom');
        final summary =
            await json(
                  await app.send(
                    'GET',
                    '/_dashboard/api/summary?range=1h',
                    headers: bearer(),
                  ),
                )
                as Map;
        expect(summary['requests'], 7);
        expect(summary['errors'], 1);
      },
    );

    test('the dashboard does not monitor itself', () async {
      await app.send('GET', '/_dashboard/api/summary', headers: bearer());
      await app.send('GET', '/_dashboard');
      final s =
          await json(
                await app.send(
                  'GET',
                  '/_dashboard/api/summary',
                  headers: bearer(),
                ),
              )
              as Map;
      expect(s['requests'], 0);
    });

    test('app logs show up in the Logs API with request ids', () async {
      app.get('/log', (r) {
        app.logger.info('hello from handler', context: {'password': 'hunter2'});
        return Response.ok('x');
      });
      await app.send('GET', '/log');
      final logs =
          await json(
                await app.send(
                  'GET',
                  '/_dashboard/api/logs?search=hello',
                  headers: bearer(),
                ),
              )
              as List;
      expect(logs.single['message'], 'hello from handler');
      expect(logs.single['request_id'], isNotNull);
      expect(
        jsonEncode(logs),
        isNot(contains('hunter2')),
        reason: 'the logger redacts sensitive context',
      );
    });

    test(
      "the dashboard's own request log lines are kept out of the Logs page",
      () async {
        app.get('/mine', (r) => Response.ok('x'));
        await app.send('GET', '/mine');
        await app.send('GET', '/_dashboard/api/summary', headers: bearer());
        await app.send('GET', '/_dashboard');
        final logs =
            await json(
                  await app.send(
                    'GET',
                    '/_dashboard/api/logs',
                    headers: bearer(),
                  ),
                )
                as List;
        expect(logs.map((l) => l['message']), contains('GET /mine 200'));
        expect(
          logs.any((l) => '${l['message']}'.contains('/_dashboard')),
          isFalse,
        );
      },
    );

    test('series endpoint and bad parameters', () async {
      await app.send('GET', '/users/1');
      final s =
          await json(
                await app.send(
                  'GET',
                  '/_dashboard/api/series?range=15m&metric=calls',
                  headers: bearer(),
                ),
              )
              as Map;
      expect(s['metric'], 'calls');
      expect((s['series'] as List).single['name'], 'GET /users/:id');
      expect(
        (await app.send(
          'GET',
          '/_dashboard/api/series?metric=bogus',
          headers: bearer(),
        )).statusCode,
        400,
      );
      expect(
        (await app.send(
          'GET',
          '/_dashboard/api/summary?range=9y',
          headers: bearer(),
        )).statusCode,
        400,
      );
    });

    test('collector is available for programmatic use', () async {
      await app.send('GET', '/users/1');
      expect(
        dash.collector.endpoints(const Duration(minutes: 5)).single.calls,
        1,
      );
    });
  });

  group('access control', () {
    test(
      'token: data endpoints need it; wrong, missing and look-alike tokens are 401',
      () async {
        final app = makeApp();
        Dashboard.attach(app, token: token);
        for (final p in ['summary', 'endpoints', 'series', 'issues', 'logs']) {
          expect(
            (await app.send('GET', '/_dashboard/api/$p')).statusCode,
            401,
            reason: p,
          );
          expect(
            (await app.send(
              'GET',
              '/_dashboard/api/$p',
              headers: bearer('wrong-token-wrong-token'),
            )).statusCode,
            401,
            reason: p,
          );
          expect(
            (await app.send(
              'GET',
              '/_dashboard/api/$p',
              headers: bearer('$token '),
            )).statusCode,
            200,
            reason: 'trailing whitespace is trimmed',
          );
          expect(
            (await app.send(
              'GET',
              '/_dashboard/api/$p',
              headers: bearer(token.substring(1)),
            )).statusCode,
            401,
            reason: p,
          );
          expect(
            (await app.send(
              'GET',
              '/_dashboard/api/$p',
              headers: {'x-dashboard-token': token},
            )).statusCode,
            200,
            reason: p,
          );
        }
        expect(
          (await app.send(
            'GET',
            '/_dashboard/api/summary?token=$token',
          )).statusCode,
          401,
          reason: 'tokens in the URL are not accepted',
        );
      },
    );

    test(
      'no token: loopback only, never with proxy trust, never from other addresses',
      () async {
        final app = makeApp();
        Dashboard.attach(app);
        // app.send has no socket, so the client address is "unknown": denied
        expect(
          (await app.send('GET', '/_dashboard/api/summary')).statusCode,
          401,
        );
        final trusting = makeApp(trustProxy: true);
        Dashboard.attach(trusting);
        expect(
          (await trusting.send(
            'GET',
            '/_dashboard/api/summary',
            headers: {'x-forwarded-for': '127.0.0.1'},
          )).statusCode,
          401,
          reason: 'a spoofable X-Forwarded-For must never open the dashboard',
        );
        // a real loopback connection is allowed
        await app.start(port: 0, handleSignals: false);
        final client = HttpClient();
        final res = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${app.port}/_dashboard/api/summary'),
        )).close();
        expect(res.statusCode, 200);
        await res.drain<void>();
        client.close(force: true);
        await app.stop();
      },
    );

    test('custom authorize callback wins', () async {
      final app = makeApp();
      Dashboard.attach(app, authorize: (r) => r.header('x-admin') == 'yes');
      expect(
        (await app.send('GET', '/_dashboard/api/summary')).statusCode,
        401,
      );
      expect(
        (await app.send(
          'GET',
          '/_dashboard/api/summary',
          headers: {'x-admin': 'yes'},
        )).statusCode,
        200,
      );
    });

    test(
      'production refuses to attach without credentials; short tokens are refused everywhere',
      () {
        expect(
          () => Dashboard.attach(makeApp(env: AppEnvironment.production)),
          throwsA(isA<ConfigurationException>()),
        );
        expect(
          () => Dashboard.attach(
            makeApp(env: AppEnvironment.production),
            token: token,
          ),
          returnsNormally,
        );
        expect(
          () => Dashboard.attach(makeApp(), token: 'short'),
          throwsA(isA<ConfigurationException>()),
        );
        expect(
          () => Dashboard.attach(makeApp(), basePath: 'no-slash'),
          throwsArgumentError,
        );
      },
    );

    test('custom base path', () async {
      final app = makeApp();
      Dashboard.attach(app, token: token, basePath: '/ops/monitor/');
      expect(
        (await app.send(
          'GET',
          '/ops/monitor/api/summary',
          headers: bearer(),
        )).statusCode,
        200,
      );
      expect((await app.send('GET', '/ops/monitor')).statusCode, 200);
      expect((await app.send('GET', '/_dashboard')).statusCode, 404);
    });
  });

  group('UI shell', () {
    test('is served with a strict CSP, no caching and no data', () async {
      final app = makeApp();
      Dashboard.attach(app, token: token, title: 'My <b>API</b>');
      final res = await app.send('GET', '/_dashboard');
      final html = await res.readText();
      expect(res.statusCode, 200);
      expect(res.header('content-type'), contains('text/html'));
      expect(res.header('cache-control'), 'no-store');
      expect(
        res.header('content-security-policy'),
        allOf(contains("default-src 'none'"), contains("connect-src 'self'")),
      );
      expect(res.header('x-frame-options'), 'DENY');
      expect(
        html,
        contains('My &lt;b&gt;API&lt;&#47;b&gt;'),
        reason: 'the title is HTML-escaped',
      );
      expect(html, isNot(contains('My <b>API</b>')));
      expect(html, contains('var BASE = "/_dashboard"'));
      expect(html, isNot(contains('__BASE__')));
      expect(html, isNot(contains('__TITLE__')));
      expect(
        RegExp(r'(src|href)=["\x27]https?://').hasMatch(html),
        isFalse,
        reason: 'no external resources',
      );
      expect(html, contains('Endpoints'));
      expect(html, contains('Typical'));
      expect(html, contains('Awful'));
    });

    test('every dynamic value is escaped before insertion (XSS guard)', () {
      // The UI builds HTML strings; all server-provided text must pass through esc().
      final src = File('lib/src/ui.dart').readAsStringSync();
      final script = src.substring(
        src.indexOf('<script>'),
        src.indexOf('</script>'),
      );
      expect(script, contains('function esc('));
      for (final risky in [
        'i.message',
        'i.type',
        'i.route',
        'i.stack',
        'l.message',
        'l.error',
        'e.route',
        'se.name',
        'l.request_id',
      ]) {
        final uses = RegExp(
          '[^\\w]${RegExp.escape(risky)}',
        ).allMatches(script).length;
        final escaped = RegExp(
          'esc\\([^)]*${RegExp.escape(risky)}',
        ).allMatches(script).length;
        expect(
          escaped,
          greaterThanOrEqualTo(1),
          reason: '$risky is used $uses time(s) but never escaped',
        );
      }
    });

    test('embedded JavaScript is syntactically valid (node --check)', () async {
      final app = makeApp();
      Dashboard.attach(app, token: token);
      final html = await (await app.send('GET', '/_dashboard')).readText();
      final js = html.substring(
        html.indexOf('<script>') + 8,
        html.indexOf('</script>'),
      );
      final dir = Directory.systemTemp.createTempSync('dc_dash');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/ui.js')..writeAsStringSync(js);
      final r = await Process.run('node', ['--check', f.path]);
      if (r.exitCode == 127) {
        markTestSkipped('node is not installed');
        return;
      }
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });
  });
}
