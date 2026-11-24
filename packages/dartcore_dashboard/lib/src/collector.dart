import 'dart:collection';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_logging/dartcore_logging.dart';

/// Limits and clock for the in-memory [Collector].
class DashboardOptions {
  const DashboardOptions({
    this.retention = const Duration(hours: 24),
    this.maxRequests = 50000,
    this.maxLogs = 5000,
    this.maxIssues = 500,
  });

  /// Requests older than this are dropped.
  final Duration retention;

  /// Hard cap on stored requests (oldest dropped first).
  final int maxRequests;
  final int maxLogs;
  final int maxIssues;
}

/// "Good" / "Medium" / "Bad" label for an endpoint.
enum Impact {
  good,
  medium,
  bad;

  String get label => switch (this) {
    good => 'Good',
    medium => 'Medium',
    bad => 'Bad',
  };
}

class _Req {
  _Req(this.time, this.method, this.route, this.status, this.ms);
  final DateTime time;
  final String method;
  final String route; // pattern, or 'UNMATCHED'
  final int status;
  final double ms;
}

class _Issue {
  _Issue(
    this.id,
    this.type,
    this.message,
    this.method,
    this.route,
    this.stack,
    DateTime t,
  ) : firstSeen = t,
      lastSeen = t;
  final String id, type, message, method, route, stack;
  final DateTime firstSeen;
  DateTime lastSeen;
  int count = 1;
  final List<String> requestIds = [];
}

class EndpointStats {
  EndpointStats({
    required this.method,
    required this.route,
    required this.calls,
    required this.errors,
    required this.avgMs,
    required this.p50,
    required this.p95,
    required this.p99,
    required this.totalMs,
    required this.share,
    required this.impact,
  });

  final String method, route;
  final int calls, errors;
  final double avgMs, p50, p95, p99, totalMs;

  /// This endpoint's share (0..1) of all request time in the window.
  final double share;
  final Impact impact;

  Map<String, Object?> toJson() => {
    'method': method,
    'route': route,
    'calls': calls,
    'errors': errors,
    'avg_ms': _r(avgMs),
    'typical_ms': _r(p50),
    'slow_ms': _r(p95),
    'awful_ms': _r(p99),
    'total_ms': _r(totalMs),
    'share': double.parse(share.toStringAsFixed(4)),
    'impact': impact.label,
  };
}

double _r(double v) => double.parse(v.toStringAsFixed(2));

/// In-memory store for the dashboard. Everything is bounded: requests by
/// count and age, logs and issues by count. Percentiles are computed on demand
/// from the retained raw samples, so they are exact for the selected window.
/// State is per process and lost on restart.
class Collector {
  Collector([
    this.options = const DashboardOptions(),
    DateTime Function()? clock,
  ]) : _now = clock ?? (() => DateTime.now().toUtc());

  final DashboardOptions options;
  final DateTime Function() _now;

  final ListQueue<_Req> _requests = ListQueue();
  final ListQueue<LogRecord> _logs = ListQueue();
  final Map<String, _Issue> _issues = {};

  // ---- ingestion ------------------------------------------------------------

  void record(RequestRecord r) {
    if (r.time.isBefore(_now().subtract(options.retention))) {
      return; // already out of the window
    }
    final route = r.route ?? 'UNMATCHED';
    _requests.add(
      _Req(r.time, r.method, route, r.status, r.duration.inMicroseconds / 1000),
    );
    _trim();
    if (r.error != null || r.status >= 500) _recordIssue(r, route);
  }

  void addLog(LogRecord r) {
    _logs.add(r);
    while (_logs.length > options.maxLogs) {
      _logs.removeFirst();
    }
  }

  void _trim() {
    final cutoff = _now().subtract(options.retention);
    while (_requests.isNotEmpty &&
        (_requests.length > options.maxRequests ||
            _requests.first.time.isBefore(cutoff))) {
      _requests.removeFirst();
    }
  }

  void _recordIssue(RequestRecord r, String route) {
    final err = r.error;
    final type = err == null ? 'HTTP ${r.status}' : err.runtimeType.toString();
    final message = err == null
        ? 'Server error without an exception'
        : _clip('$err', 300);
    final stack = r.stackTrace?.toString() ?? '';
    final frame = RegExp(r'#\d+\s+(.+)').firstMatch(stack)?.group(1) ?? '';
    final id = _hash('$type|${r.method}|$route|$frame');
    final existing = _issues[id];
    final issue =
        existing ??
        _Issue(
          id,
          type,
          message,
          r.method,
          route,
          _clipLines(stack, 25),
          r.time,
        );
    if (existing == null) {
      _issues[id] = issue;
    } else {
      issue.count++;
    }
    issue.lastSeen = r.time;
    if (r.requestId != null) {
      issue.requestIds.add(r.requestId!);
      if (issue.requestIds.length > 5) issue.requestIds.removeAt(0);
    }
    while (_issues.length > options.maxIssues) {
      final oldest = _issues.values.reduce(
        (a, b) => a.lastSeen.isBefore(b.lastSeen) ? a : b,
      );
      _issues.remove(oldest.id);
    }
  }

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
  static String _clipLines(String s, int n) => s.split('\n').take(n).join('\n');
  static String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h.toRadixString(16);
  }

  // ---- queries ---------------------------------------------------------------

  Iterable<_Req> _window(Duration range) {
    final cutoff = _now().subtract(range);
    return _requests.where((r) => !r.time.isBefore(cutoff));
  }

  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  /// Per-endpoint statistics, most impactful first.
  ///
  /// "Typical" is the median, "slow" the 95th and "awful" the 99th percentile.
  /// **Impact** is a heuristic: *Bad* if p95 > 3 s or more than 5% of calls
  /// failed (5xx); *Medium* if p95 > 1 s, or if the endpoint uses over 25% of
  /// all request time **and** its p95 exceeds 200 ms (a fast endpoint is never
  /// "Medium" just because everything else is faster); otherwise *Good*.
  List<EndpointStats> endpoints(
    Duration range, {
    String? search,
    String? method,
  }) {
    final groups = <String, List<_Req>>{};
    var total = 0.0;
    for (final r in _window(range)) {
      (groups['${r.method} ${r.route}'] ??= []).add(r);
      total += r.ms;
    }
    final out = <EndpointStats>[];
    for (final e in groups.entries) {
      final list = e.value;
      if (method != null &&
          method.isNotEmpty &&
          method != 'All' &&
          list.first.method != method) {
        continue;
      }
      if (search != null &&
          search.isNotEmpty &&
          !e.key.toLowerCase().contains(search.toLowerCase())) {
        continue;
      }
      final ms = [for (final r in list) r.ms]..sort();
      final sum = ms.fold<double>(0, (a, b) => a + b);
      final errors = list.where((r) => r.status >= 500).length;
      final p95 = _percentile(ms, 95);
      final share = total == 0 ? 0.0 : sum / total;
      final impact = p95 > 3000 || errors / list.length > 0.05
          ? Impact.bad
          : (p95 > 1000 || (groups.length > 1 && share > 0.25)
                ? Impact.medium
                : Impact.good);
      out.add(
        EndpointStats(
          method: list.first.method,
          route: list.first.route,
          calls: list.length,
          errors: errors,
          avgMs: sum / list.length,
          p50: _percentile(ms, 50),
          p95: p95,
          p99: _percentile(ms, 99),
          totalMs: sum,
          share: share,
          impact: impact,
        ),
      );
    }
    out.sort((a, b) => b.totalMs.compareTo(a.totalMs));
    return out;
  }

  Map<String, Object?> summary(Duration range) {
    final reqs = _window(range).toList();
    final ms = [for (final r in reqs) r.ms]..sort();
    final errors = reqs.where((r) => r.status >= 500).length;
    final classes = <String, int>{};
    for (final r in reqs) {
      final c = '${r.status ~/ 100}xx';
      classes[c] = (classes[c] ?? 0) + 1;
    }
    return {
      'range_seconds': range.inSeconds,
      'requests': reqs.length,
      'errors': errors,
      'error_rate': reqs.isEmpty
          ? 0.0
          : double.parse((errors / reqs.length).toStringAsFixed(4)),
      'requests_per_minute': double.parse(
        (reqs.length / (range.inSeconds / 60)).toStringAsFixed(2),
      ),
      'typical_ms': _r(_percentile(ms, 50)),
      'slow_ms': _r(_percentile(ms, 95)),
      'awful_ms': _r(_percentile(ms, 99)),
      'endpoints': {for (final r in reqs) '${r.method} ${r.route}'}.length,
      'issues': _issues.length,
      'status_classes': classes,
      'retained_requests': _requests.length,
    };
  }

  /// Time series for a stacked chart: the five heaviest endpoints plus "Other".
  /// [metric] is `total_time` (seconds), `calls` or `errors`.
  Map<String, Object?> series(
    Duration range, {
    String metric = 'total_time',
    int buckets = 60,
  }) {
    if (!const {'total_time', 'calls', 'errors'}.contains(metric)) {
      throw ArgumentError('Unknown metric "$metric".');
    }
    final end = _now();
    final start = end.subtract(range);
    final widthMs = (range.inMilliseconds / buckets).ceil().clamp(
      1000,
      1 << 40,
    );
    final n = (range.inMilliseconds / widthMs).ceil();
    final reqs = _window(range).toList();
    final totals = <String, double>{};
    for (final r in reqs) {
      totals['${r.method} ${r.route}'] =
          (totals['${r.method} ${r.route}'] ?? 0) + r.ms;
    }
    final top =
        (totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .map((e) => e.key)
            .toList();
    final rows = {
      for (final k in [...top, 'Other']) k: List<double>.filled(n, 0),
    };
    for (final r in reqs) {
      final i = ((r.time.difference(start).inMilliseconds) / widthMs)
          .floor()
          .clamp(0, n - 1);
      final key = rows.containsKey('${r.method} ${r.route}')
          ? '${r.method} ${r.route}'
          : 'Other';
      if (metric == 'errors' && r.status < 500) continue;
      rows[key]![i] += metric == 'total_time' ? r.ms / 1000 : 1;
    }
    return {
      'metric': metric,
      'unit': metric == 'total_time' ? 's' : '',
      'start': start.millisecondsSinceEpoch,
      'bucket_ms': widthMs,
      'series': [
        for (final e in rows.entries)
          if (e.key != 'Other' || e.value.any((v) => v > 0))
            {
              'name': e.key,
              'values': [
                for (final v in e.value) double.parse(v.toStringAsFixed(3)),
              ],
            },
      ],
    };
  }

  List<Map<String, Object?>> issues({String? search}) {
    final list = _issues.values.where((i) {
      if (search == null || search.isEmpty) return true;
      final q = search.toLowerCase();
      return i.type.toLowerCase().contains(q) ||
          i.message.toLowerCase().contains(q) ||
          i.route.toLowerCase().contains(q);
    }).toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return [
      for (final i in list)
        {
          'id': i.id,
          'type': i.type,
          'message': i.message,
          'method': i.method,
          'route': i.route,
          'count': i.count,
          'first_seen': i.firstSeen.toIso8601String(),
          'last_seen': i.lastSeen.toIso8601String(),
          'stack': i.stack,
          'request_ids': i.requestIds,
        },
    ];
  }

  List<Map<String, Object?>> logs({
    String? level,
    String? search,
    String? requestId,
    int limit = 200,
  }) {
    final min = level == null || level.isEmpty
        ? LogLevel.debug
        : LogLevel.parse(level, LogLevel.debug);
    final q = search?.toLowerCase();
    final out = <Map<String, Object?>>[];
    for (final r in _logs.toList().reversed) {
      if (r.level.index < min.index) continue;
      if (requestId != null &&
          requestId.isNotEmpty &&
          r.requestId != requestId) {
        continue;
      }
      if (q != null &&
          q.isNotEmpty &&
          !('${r.message} ${r.error ?? ''}'.toLowerCase().contains(q))) {
        continue;
      }
      out.add({
        'time': r.time.toUtc().toIso8601String(),
        'level': r.level.name,
        'message': r.message,
        'request_id': r.requestId,
        'context': r.context,
        'error': r.error?.toString(),
      });
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Drops all collected data.
  void clear() {
    _requests.clear();
    _logs.clear();
    _issues.clear();
  }
}

/// Stores log records for the dashboard's Logs page.
class DashboardLogHandler implements LogHandler {
  DashboardLogHandler(this.collector, {this.ignore});
  final Collector collector;

  /// Return true to keep a record out of the dashboard (used to hide the
  /// request lines of the dashboard's own polling).
  final bool Function(LogRecord record)? ignore;

  @override
  void handle(LogRecord record) {
    if (ignore?.call(record) ?? false) {
      return;
    }
    collector.addLog(record);
  }

  @override
  Future<void> close() async {}
}
