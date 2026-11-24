import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_dashboard/dartcore_dashboard.dart';
import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:test/test.dart';

DateTime t0 = DateTime.utc(2025, 1, 1, 12);

RequestRecord rec(
  String method,
  String? route,
  int ms, {
  int status = 200,
  int secondsAgo = 0,
  Object? error,
  StackTrace? stack,
  String? id,
}) => RequestRecord(
  time: t0.subtract(Duration(seconds: secondsAgo)),
  method: method,
  path: route ?? '/x',
  route: route,
  status: status,
  duration: Duration(milliseconds: ms),
  ip: '127.0.0.1',
  requestId: id,
  error: error,
  stackTrace: stack,
);

void main() {
  late Collector c;
  setUp(() => c = Collector(const DashboardOptions(), () => t0));

  group('endpoint statistics', () {
    test('calls, percentiles (nearest rank) and ordering by total time', () {
      for (var i = 1; i <= 100; i++) {
        c.record(rec('GET', '/slow', i * 10)); // 10..1000 ms
      }
      for (var i = 0; i < 50; i++) {
        c.record(rec('POST', '/fast', 5));
      }
      final e = c.endpoints(const Duration(hours: 1));
      expect(e.map((x) => '${x.method} ${x.route}'), [
        'GET /slow',
        'POST /fast',
      ]);
      final s = e.first;
      expect(s.calls, 100);
      expect(s.p50, 500);
      expect(s.p95, 950);
      expect(s.p99, 990);
      expect(s.avgMs, closeTo(505, 0.01));
      expect(e.last.calls, 50);
      expect(e.last.p50, 5);
    });

    test('time window excludes old requests', () {
      c.record(rec('GET', '/a', 10, secondsAgo: 30));
      c.record(rec('GET', '/a', 10, secondsAgo: 7200));
      expect(c.endpoints(const Duration(minutes: 15)).single.calls, 1);
      expect(c.endpoints(const Duration(hours: 6)).single.calls, 2);
    });

    test(
      'search and method filters; unmatched routes are grouped, not exploded per path',
      () {
        for (var i = 0; i < 5; i++) {
          c.record(rec('GET', null, 1, status: 404));
        }
        c.record(rec('GET', '/users/:id', 3));
        c.record(rec('POST', '/users', 3));
        expect(
          c.endpoints(const Duration(hours: 1)).map((e) => e.route),
          containsAll(['UNMATCHED', '/users/:id', '/users']),
        );
        expect(
          c.endpoints(const Duration(hours: 1), search: 'users').length,
          2,
        );
        expect(
          c.endpoints(const Duration(hours: 1), method: 'POST').single.route,
          '/users',
        );
        expect(c.endpoints(const Duration(hours: 1), method: 'All').length, 3);
      },
    );

    test(
      'impact heuristic: Bad on slow p95 or error rate, Medium on slow-ish or dominant, else Good',
      () {
        for (var i = 0; i < 20; i++) {
          c.record(rec('GET', '/terrible', 4000));
          c.record(rec('GET', '/flaky', 10, status: i < 3 ? 500 : 200));
          c.record(rec('GET', '/slowish', 1500));
          c.record(rec('GET', '/hog', 400));
          c.record(rec('GET', '/tiny', 1));
        }
        Impact of(String r) => c
            .endpoints(const Duration(hours: 1))
            .firstWhere((e) => e.route == r)
            .impact;
        expect(of('/terrible'), Impact.bad);
        expect(of('/flaky'), Impact.bad, reason: '15% of calls failed');
        expect(of('/slowish'), Impact.medium);
        expect(of('/tiny'), Impact.good);
        // a lone endpoint is never "Medium" just for using 100% of the time
        final solo = Collector(const DashboardOptions(), () => t0)
          ..record(rec('GET', '/only', 50));
        expect(
          solo.endpoints(const Duration(hours: 1)).single.impact,
          Impact.good,
        );
      },
    );
  });

  test('summary: totals, error rate, status classes, rpm', () {
    for (var i = 0; i < 8; i++) {
      c.record(rec('GET', '/a', 10));
    }
    c.record(rec('GET', '/a', 10, status: 404));
    c.record(rec('GET', '/a', 10, status: 500, error: StateError('x')));
    final s = c.summary(const Duration(minutes: 10));
    expect(s['requests'], 10);
    expect(s['errors'], 1);
    expect(s['error_rate'], 0.1);
    expect(s['status_classes'], {'2xx': 8, '4xx': 1, '5xx': 1});
    expect(s['requests_per_minute'], 1.0);
    expect(s['issues'], 1);
    expect(c.summary(const Duration(hours: 1))['requests'], 10);
    expect(
      Collector(
        const DashboardOptions(),
        () => t0,
      ).summary(const Duration(hours: 1))['typical_ms'],
      0,
    );
  });

  group('series', () {
    test('buckets by time, top five endpoints plus Other, metrics', () {
      for (var e = 0; e < 8; e++) {
        for (var i = 0; i < 10 - e; i++) {
          c.record(rec('GET', '/e$e', 100, secondsAgo: 30 + i));
        }
      }
      c.record(rec('GET', '/e0', 100, status: 500, secondsAgo: 5));
      final s = c.series(const Duration(minutes: 15));
      final names = [for (final x in s['series']! as List) (x as Map)['name']];
      expect(names.length, 6);
      expect(names.last, 'Other');
      expect(names.first, 'GET /e0');
      final calls = c.series(const Duration(minutes: 15), metric: 'calls');
      final total = (calls['series']! as List)
          .expand((x) => ((x as Map)['values'] as List).cast<num>())
          .fold<num>(0, (a, b) => a + b);
      expect(total, c.summary(const Duration(minutes: 15))['requests']);
      final errors = c.series(const Duration(minutes: 15), metric: 'errors');
      expect(
        ((errors['series']! as List).expand(
          (x) => ((x as Map)['values'] as List).cast<num>(),
        )).fold<num>(0, (a, b) => a + b),
        1,
      );
      expect(
        () => c.series(const Duration(hours: 1), metric: 'bogus'),
        throwsArgumentError,
      );
    });

    test('empty window yields an empty series list', () {
      expect(c.series(const Duration(hours: 1))['series'], isEmpty);
    });
  });

  group('issues', () {
    test(
      'same error at the same place is grouped; different place or type is separate',
      () {
        StackTrace st(String frame) => StackTrace.fromString(
          '#0      $frame (package:app/x.dart:1:1)\n#1      main (package:app/main.dart:2:2)',
        );
        for (var i = 0; i < 3; i++) {
          c.record(
            rec(
              'GET',
              '/a',
              5,
              status: 500,
              error: StateError('boom $i'),
              stack: st('handler'),
              id: 'req-$i',
            ),
          );
        }
        c.record(
          rec(
            'GET',
            '/b',
            5,
            status: 500,
            error: StateError('boom'),
            stack: st('handler'),
          ),
        );
        c.record(
          rec(
            'GET',
            '/a',
            5,
            status: 500,
            error: ArgumentError('x'),
            stack: st('handler'),
          ),
        );
        c.record(rec('GET', '/a', 5, status: 500)); // 5xx with no exception
        final issues = c.issues();
        expect(issues.length, 4);
        final grouped = issues.firstWhere(
          (i) => i['type'] == 'StateError' && i['route'] == '/a',
        );
        expect(grouped['count'], 3);
        expect(grouped['request_ids'], ['req-0', 'req-1', 'req-2']);
        expect(grouped['stack'], contains('handler'));
        expect(issues.any((i) => i['type'] == 'HTTP 500'), isTrue);
        expect(c.issues(search: 'argument').single['type'], 'ArgumentError');
      },
    );

    test('4xx responses are not issues; issue table is bounded', () {
      c.record(rec('GET', '/a', 5, status: 404));
      c.record(rec('GET', '/a', 5, status: 422));
      expect(c.issues(), isEmpty);
      final small = Collector(const DashboardOptions(maxIssues: 3), () => t0);
      for (var i = 0; i < 10; i++) {
        small.record(
          rec(
            'GET',
            '/r$i',
            5,
            status: 500,
            error: StateError('e'),
            secondsAgo: 100 - i,
          ),
        );
      }
      expect(small.issues().length, 3);
      expect(small.issues().first['route'], '/r9', reason: 'newest kept');
    });

    test('long messages are clipped', () {
      c.record(rec('GET', '/a', 5, status: 500, error: StateError('x' * 5000)));
      expect((c.issues().single['message'] as String).length, lessThan(400));
    });
  });

  group('logs', () {
    LogRecord log(LogLevel l, String m, {String? rid}) => LogRecord(
      level: l,
      message: m,
      time: t0,
      requestId: rid,
      error: l == LogLevel.error ? 'bad' : null,
    );

    test('filter by level, text and request id, newest first, bounded', () {
      c.addLog(log(LogLevel.debug, 'tick'));
      c.addLog(log(LogLevel.info, 'GET /users 200', rid: 'r1'));
      c.addLog(log(LogLevel.error, 'db failed', rid: 'r2'));
      expect(c.logs().map((l) => l['message']), [
        'db failed',
        'GET /users 200',
        'tick',
      ]);
      expect(c.logs(level: 'info').length, 2);
      expect(c.logs(level: 'error').single['error'], 'bad');
      expect(c.logs(search: 'USERS').single['request_id'], 'r1');
      expect(c.logs(requestId: 'r2').single['message'], 'db failed');
      expect(c.logs(limit: 1).length, 1);
      final small = Collector(const DashboardOptions(maxLogs: 5), () => t0);
      for (var i = 0; i < 20; i++) {
        small.addLog(log(LogLevel.info, 'm$i'));
      }
      expect(small.logs().length, 5);
      expect(small.logs().first['message'], 'm19');
    });
  });

  test('memory is bounded by count and by age', () {
    final small = Collector(
      const DashboardOptions(
        maxRequests: 100,
        retention: Duration(minutes: 10),
      ),
      () => t0,
    );
    for (var i = 0; i < 500; i++) {
      small.record(rec('GET', '/a', 1));
    }
    expect(small.summary(const Duration(hours: 1))['retained_requests'], 100);
    small.record(rec('GET', '/old', 1, secondsAgo: 3600));
    small.record(rec('GET', '/new', 1));
    expect(
      small.endpoints(const Duration(hours: 24)).any((e) => e.route == '/old'),
      isFalse,
    );
    small.clear();
    expect(small.summary(const Duration(hours: 1))['requests'], 0);
  });
}
