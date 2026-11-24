import 'dart:io';

import 'package:dartcore_logging/dartcore_logging.dart';
import 'package:test/test.dart';

void main() {
  test('filters by level and redacts sensitive keys', () {
    final mem = MemoryHandler();
    final log = Logger(level: LogLevel.info, handlers: [mem]);
    log.debug('hidden');
    log.info(
      'login',
      context: {
        'email': 'a@b.c',
        'password': 'hunter2',
        'nested': {'Authorization': 'Bearer abc', 'ok': 1},
        'list': [
          {'api_key': 'k'},
        ],
      },
    );
    expect(mem.records, hasLength(1));
    final ctx = mem.records.single.context;
    expect(ctx['email'], 'a@b.c');
    expect(ctx['password'], Redactor.mask);
    expect((ctx['nested'] as Map)['Authorization'], Redactor.mask);
    expect((ctx['nested'] as Map)['ok'], 1);
    expect(((ctx['list'] as List).single as Map)['api_key'], Redactor.mask);
  });

  test('request id flows through zones', () {
    final mem = MemoryHandler();
    final log = Logger(handlers: [mem]);
    runWithRequestId('req-1', () => log.info('inside'));
    log.info('outside');
    expect(mem.records[0].requestId, 'req-1');
    expect(mem.records[1].requestId, isNull);
  });

  test('file handler writes json lines', () async {
    final dir = Directory.systemTemp.createTempSync('dc_log');
    final h = FileHandler('${dir.path}/logs/app.log');
    final log = Logger(handlers: [h]);
    log.error('boom', error: StateError('x'));
    await log.close();
    final text = File('${dir.path}/logs/app.log').readAsStringSync();
    expect(text, contains('"level":"error"'));
    expect(text, contains('boom'));
    dir.deleteSync(recursive: true);
  });
}
