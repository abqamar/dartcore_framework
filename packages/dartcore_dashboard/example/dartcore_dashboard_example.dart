// Attaches the monitoring dashboard to an App and reads its data API in-process (ran for real).
//
// Observed output of `dart run example/dartcore_dashboard_example.dart`:
//
//   GET /_dashboard -> 200
//   GET /_dashboard/api/summary (no token) -> 401
//   GET /users/:id calls=5 errors5xx=0
//   GET /boom calls=1 errors5xx=1
//   issues: 1

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_dashboard/dartcore_dashboard.dart';
import 'package:dartcore_logging/dartcore_logging.dart';

Future<void> main() async {
  final app = App(
    config: const AppConfig(environment: AppEnvironment.testing),
    logger: Logger(level: LogLevel.error, handlers: [MemoryHandler()]),
  );

  // The token must be at least 16 characters. In production, load it from
  // configuration (Config.require('DASHBOARD_TOKEN')); never hard-code it.
  const token = 'example-dashboard-token';
  Dashboard.attach(app, token: token);

  app.get('/users/:id', (request) => Response.ok({'id': request.param('id')}));
  app.get('/boom', (request) => throw StateError('something broke'));

  // Generate some traffic (in-process, no socket needed).
  for (var i = 0; i < 5; i++) {
    await app.send('GET', '/users/$i');
  }
  await app.send('GET', '/boom');

  // The HTML shell is public (it contains no data); data endpoints need the token.
  final shell = await app.send('GET', '/_dashboard');
  print('GET /_dashboard -> ${shell.statusCode}');
  final denied = await app.send('GET', '/_dashboard/api/summary');
  print('GET /_dashboard/api/summary (no token) -> ${denied.statusCode}');

  final headers = {'authorization': 'Bearer $token'};
  final endpoints =
      await (await app.send(
            'GET',
            '/_dashboard/api/endpoints?range=15m',
            headers: headers,
          )).readJson()
          as List;
  for (final e in endpoints) {
    print(
      '${e['method']} ${e['route']} calls=${e['calls']} errors5xx=${e['errors']}',
    );
  }
  final issues = await (await app.send(
    'GET',
    '/_dashboard/api/issues',
    headers: headers,
  )).readJson();
  print('issues: ${(issues as List).length}');
}
