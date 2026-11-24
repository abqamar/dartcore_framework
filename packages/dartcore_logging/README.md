# dartcore_logging

Structured logging with secret redaction, request-id correlation and console, file and in-memory handlers for DartCore backends.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. `dartcore_framework` re-exports this package.

## Install

```sh
dart pub add dartcore_logging
```

## Usage

```dart
import 'package:dartcore_logging/dartcore_logging.dart';

void main() {
  Log.info('Server started');
  Log.error('Database connection failed', error: Exception('timeout'));

  // Sensitive context keys are masked automatically.
  Log.info('login', context: {'email': 'a@example.com', 'password': 'hunter2'}); // password -> [REDACTED]

  // Configure level and handlers once at startup.
  Log.use(Logger(
    level: LogLevel.info,
    handlers: [ConsoleHandler(json: true), FileHandler('storage/logs/app.log')],
  ));
}
```

- Levels: `debug`, `info`, `warning`, `error`, `fatal`. Errors go to stderr.
- Handlers: `ConsoleHandler` (pretty or JSON lines), `FileHandler` (appends JSON lines), `MemoryHandler` (for tests), or implement `LogHandler`.
- Context keys such as `password`, `secret`, `token`, `authorization`, `api_key`, `cookie` are masked recursively; add more with `Redactor(extraKeys: [...])`.
- Inside a request handled by `dartcore_api`, records carry the request id automatically (zone based).

A runnable program is in [`example/`](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_logging/example/dartcore_logging_example.dart).

## Status and limits

Pre-1.0: the API may change. `FileHandler` does not rotate files; use logrotate or your platform's log shipping.
Redaction is key-name based: it cannot find secrets inside free-text messages, so do not log them.
More in [caching and logging](https://github.com/abqamar/dartcore_framework/blob/main/docs/cache-logging.md).
