import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_dashboard/dartcore_dashboard.dart';

/// A demo app with the monitoring dashboard attached and a built-in traffic
/// generator so the charts have something to show.
///
///   dart run bin/dashboard_demo.dart            # then open http://127.0.0.1:8090/_dashboard
///   DASHBOARD_TOKEN=... dart run ...            # require a token instead of loopback-only
Future<void> main() async {
  final app = DartCore(config: const AppConfig(port: 8090));
  Dashboard.attach(
    app,
    token: Platform.environment['DASHBOARD_TOKEN'],
    title: 'Backend API',
  );

  final rng = Random(7);
  Future<void> work(int baseMs, [int jitter = 0]) => Future<void>.delayed(
    Duration(milliseconds: baseMs + (jitter == 0 ? 0 : rng.nextInt(jitter))),
  );

  app.post('/api/checkout', (r) async {
    await work(300, 250);
    if (rng.nextInt(25) == 0) {
      throw StateError('Payment gateway timeout');
    }
    return Response.ok({'ok': true});
  });
  app.get('/api/recommendations', (r) async {
    await work(250, 220);
    return Response.ok([]);
  });
  app.get('/api/search', (r) async {
    await work(120, 200);
    return Response.ok([]);
  });
  app.get('/api/products', (r) async {
    await work(40, 80);
    app.logger.info('products listed');
    return Response.ok([]);
  });
  app.post('/api/login', (r) async {
    await work(20, 40);
    if (rng.nextInt(12) == 0) {
      app.logger.warning(
        'failed login attempt',
        context: {'ip': r.ip, 'password': 'hunter2'},
      );
    }
    return Response.ok({});
  });
  app.get('/api/users/:id', (r) async {
    await work(8, 20);
    return Response.ok({'id': r.param('id')});
  });
  app.put('/api/cart', (r) async {
    await work(25, 40);
    return Response.ok({});
  });
  app.get('/api/report', (r) async {
    await work(60, 30);
    throw ArgumentError('Invalid date range');
  });

  await app.start(host: '127.0.0.1');

  // traffic generator
  final client = HttpClient();
  final calls = <(String, String, int)>[
    ('POST', '/api/checkout', 6),
    ('GET', '/api/recommendations', 6),
    ('GET', '/api/search', 10),
    ('GET', '/api/products', 8),
    ('POST', '/api/login', 5),
    ('GET', '/api/users/42', 8),
    ('PUT', '/api/cart', 3),
    ('GET', '/api/report', 1),
    ('GET', '/api/missing', 1),
  ];
  final bag = [
    for (final c in calls)
      for (var i = 0; i < c.$3; i++) c,
  ];
  Timer.periodic(const Duration(milliseconds: 60), (_) async {
    final c = bag[rng.nextInt(bag.length)];
    try {
      final req = await client.openUrl(
        c.$1,
        Uri.parse('http://127.0.0.1:${app.port}${c.$2}'),
      );
      await (await req.close()).drain<void>();
    } catch (_) {}
  });
  stdout.writeln('Dashboard: http://127.0.0.1:${app.port}/_dashboard');
}
