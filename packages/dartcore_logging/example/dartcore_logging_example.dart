// Structured logging with redaction (no server needed). Timestamps vary per run.
//
// Observed output of `dart run example/dartcore_logging_example.dart`:
//
//   2026-11-24T17:12:19.641136 [INFO] Server started
//   {"time":"2026-11-24T13:12:19.650068Z","level":"debug","message":"debug is enabled now"}
//   {"time":"2026-11-24T13:12:19.651672Z","level":"info","message":"login","context":{"email":"a@example.com","password":"[REDACTED]"}}
//   {"time":"2026-11-24T13:12:19.652903Z","level":"warning","message":"slow query","context":{"ms":1200}}
//   captured 3 records in memory
//   password in memory record: [REDACTED]

import 'package:dartcore_logging/dartcore_logging.dart';

void main() {
  // Pretty console output (the default handler).
  Log.info('Server started');

  // JSON lines, e.g. for log shippers. Sensitive context keys are masked.
  final memory = MemoryHandler();
  Log.use(
    Logger(
      level: LogLevel.debug,
      handlers: [ConsoleHandler(json: true), memory],
    ),
  );
  Log.debug('debug is enabled now');
  Log.info('login', context: {'email': 'a@example.com', 'password': 'hunter2'});
  Log.warning('slow query', context: {'ms': 1200});

  print('captured ${memory.records.length} records in memory');
  print('password in memory record: ${memory.records[1].context['password']}');
}
