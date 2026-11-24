import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum LogLevel {
  debug,
  info,
  warning,
  error,
  fatal;

  static LogLevel parse(String? v, [LogLevel fallback = LogLevel.info]) {
    for (final l in values) {
      if (l.name == v?.toLowerCase()) return l;
    }
    return fallback;
  }
}

/// Zone key under which the current request id is stored.
const Symbol requestIdZoneKey = #dartcoreRequestId;

/// Runs [body] so every log record created inside carries [requestId].
R runWithRequestId<R>(String requestId, R Function() body) =>
    runZoned(body, zoneValues: {requestIdZoneKey: requestId});

class LogRecord {
  LogRecord({
    required this.level,
    required this.message,
    required this.time,
    this.context = const {},
    this.error,
    this.stackTrace,
    this.requestId,
  });

  final LogLevel level;
  final String message;
  final DateTime time;
  final Map<String, Object?> context;
  final Object? error;
  final StackTrace? stackTrace;
  final String? requestId;

  Map<String, Object?> toJson({bool includeStackTrace = true}) => {
    'time': time.toUtc().toIso8601String(),
    'level': level.name,
    'message': message,
    if (requestId != null) 'request_id': requestId,
    if (context.isNotEmpty) 'context': context,
    if (error != null) 'error': error.toString(),
    if (includeStackTrace && stackTrace != null)
      'stack_trace': stackTrace.toString(),
  };
}

abstract interface class LogHandler {
  void handle(LogRecord record);
  Future<void> close();
}

/// Masks values whose key looks sensitive (password, token, secret, ...).
class Redactor {
  Redactor({Iterable<String> extraKeys = const []})
    : _pattern = RegExp(
        [
          'password',
          'passwd',
          'secret',
          'token',
          'authorization',
          'api[_-]?key',
          'cookie',
          'credential',
          'private[_-]?key',
          'card[_-]?number',
          'cvv',
          ...extraKeys.map(RegExp.escape),
        ].join('|'),
        caseSensitive: false,
      );

  final RegExp _pattern;
  static const mask = '[REDACTED]';

  Object? redact(Object? value, [String? key, int depth = 0]) {
    if (key != null && _pattern.hasMatch(key)) return mask;
    if (depth > 8) return '[truncated]';
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key.toString(): redact(e.value, e.key.toString(), depth + 1),
      };
    }
    if (value is Iterable) {
      return [for (final v in value) redact(v, null, depth + 1)];
    }
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    return value.toString();
  }
}

/// Writes records to stdout/stderr, either as JSON lines or human-readable text.
class ConsoleHandler implements LogHandler {
  ConsoleHandler({
    this.json = false,
    this.includeStackTrace = true,
    IOSink? out,
    IOSink? err,
  }) : _out = out ?? stdout,
       _err = err ?? stderr;

  final bool json;
  final bool includeStackTrace;
  final IOSink _out;
  final IOSink _err;

  @override
  void handle(LogRecord r) {
    final sink = r.level.index >= LogLevel.error.index ? _err : _out;
    if (json) {
      sink.writeln(jsonEncode(r.toJson(includeStackTrace: includeStackTrace)));
      return;
    }
    final b = StringBuffer(
      '${r.time.toIso8601String()} [${r.level.name.toUpperCase()}]',
    );
    if (r.requestId != null) b.write(' [${r.requestId}]');
    b.write(' ${r.message}');
    if (r.context.isNotEmpty) b.write(' ${jsonEncode(r.context)}');
    if (r.error != null) b.write('\n  error: ${r.error}');
    if (includeStackTrace && r.stackTrace != null) b.write('\n${r.stackTrace}');
    sink.writeln(b);
  }

  @override
  Future<void> close() async {}
}

/// Appends JSON-line records to a file.
class FileHandler implements LogHandler {
  FileHandler(String path) : _sink = _open(path);

  final IOSink _sink;

  static IOSink _open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return file.openWrite(mode: FileMode.append);
  }

  @override
  void handle(LogRecord record) => _sink.writeln(jsonEncode(record.toJson()));

  @override
  Future<void> close() => _sink.close();
}

/// Collects records in memory; useful in tests.
class MemoryHandler implements LogHandler {
  final List<LogRecord> records = [];
  @override
  void handle(LogRecord record) => records.add(record);
  @override
  Future<void> close() async {}
}

class Logger {
  Logger({
    this.level = LogLevel.info,
    List<LogHandler>? handlers,
    Redactor? redactor,
  }) : handlers = handlers ?? [ConsoleHandler()],
       redactor = redactor ?? Redactor();

  LogLevel level;
  final List<LogHandler> handlers;
  final Redactor redactor;

  void log(
    LogLevel lvl,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (lvl.index < level.index) return;
    final record = LogRecord(
      level: lvl,
      message: message,
      time: DateTime.now(),
      context: context == null
          ? const {}
          : (redactor.redact(context) as Map).cast<String, Object?>(),
      error: error,
      stackTrace: stackTrace,
      requestId: Zone.current[requestIdZoneKey] as String?,
    );
    for (final h in handlers) {
      h.handle(record);
    }
  }

  void debug(String m, {Map<String, Object?>? context}) =>
      log(LogLevel.debug, m, context: context);
  void info(String m, {Map<String, Object?>? context}) =>
      log(LogLevel.info, m, context: context);
  void warning(String m, {Map<String, Object?>? context, Object? error}) =>
      log(LogLevel.warning, m, context: context, error: error);
  void error(
    String m, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => log(
    LogLevel.error,
    m,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );
  void fatal(
    String m, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => log(
    LogLevel.fatal,
    m,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  Future<void> close() async {
    for (final h in handlers) {
      await h.close();
    }
  }
}

/// Static facade over a managed default [Logger].
///
/// ```dart
/// Log.info('Server started');
/// Log.error('Database connection failed', error: e);
/// ```
abstract final class Log {
  static Logger _instance = Logger();

  static Logger get instance => _instance;
  static void use(Logger logger) => _instance = logger;
  static void reset() => _instance = Logger();
  static set level(LogLevel l) => _instance.level = l;

  static void debug(String m, {Map<String, Object?>? context}) =>
      _instance.debug(m, context: context);
  static void info(String m, {Map<String, Object?>? context}) =>
      _instance.info(m, context: context);
  static void warning(
    String m, {
    Map<String, Object?>? context,
    Object? error,
  }) => _instance.warning(m, context: context, error: error);
  static void error(
    String m, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => _instance.error(
    m,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );
  static void fatal(
    String m, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => _instance.fatal(
    m,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );
}
