import 'dart:async';
import 'dart:io';

import 'package:dartcore_mssql/dartcore_mssql.dart';
import 'package:test/test.dart';

SqlServerDiagnosis connect(
  Object error, {
  int? number,
  String? message,
  String? password,
}) => diagnoseSqlServerConnectError(
  error,
  host: 'db.local',
  port: 1433,
  database: 'app',
  username: 'sa',
  password: password,
  number: number,
  message: message,
);

void main() {
  group('query errors', () {
    test('known numbers get a hint', () {
      for (final n in [2714, 2627, 2601, 515, 547, 208, 207, 229, 1205, 8152]) {
        final d = diagnoseSqlServerQueryError(number: n, text: 'x');
        expect(d.hint, isNotNull, reason: '$n');
        expect(d.details, startsWith('[$n] x'));
      }
    });

    test('unknown numbers keep the details and have no hint', () {
      final d = diagnoseSqlServerQueryError(
        number: 99999,
        text: 'weird',
        severity: 16,
        state: 3,
      );
      expect(d.hint, isNull);
      expect(d.details, '[99999] weird (severity 16, state 3)');
    });

    test('2714 mentions migrations', () {
      expect(
        diagnoseSqlServerQueryError(number: 2714, text: 'x').hint,
        contains('migration'),
      );
    });
  });

  group('connect errors', () {
    test('login failed (18456)', () {
      final d = connect(
        Object(),
        number: 18456,
        message: "Login failed for user 'sa'.",
      );
      expect(d.hint, contains('username'));
      expect(d.details, startsWith('[18456]'));
    });

    test('cannot open database (4060)', () {
      expect(
        connect(Object(), number: 4060, message: 'x').hint,
        contains('"app"'),
      );
    });

    test('connection refused', () {
      final d = connect(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        ),
      );
      expect(d.hint, contains('db.local:1433'));
      expect(d.hint, contains('listening'));
    });

    test('connection refused as the driver actually words it', () {
      // Observed from mssql_dart 1.0.0 against a closed port: not a SocketException.
      final d = connect(
        Exception('Failed to connect to localhost:1433: Connection refused'),
      );
      expect(d.hint, contains('listening'));
      expect(d.hint, contains('db.local:1433'));
    });

    test('DNS failure', () {
      final d = connect(const SocketException('Failed host lookup: db.local'));
      expect(d.hint, contains('DNS'));
    });

    test('timeout', () {
      expect(connect(TimeoutException('x')).hint, contains('Timed out'));
    });

    test('certificate problems point at ssl modes', () {
      final d = connect(
        Object(),
        message: 'certificate verify failed: self signed certificate',
      );
      expect(d.hint, contains('SslMode.require'));
    });

    test('fallback hint is generic but names the endpoint', () {
      expect(
        connect(Object(), message: 'mystery').hint,
        contains('db.local:1433'),
      );
    });

    test('the password is never included', () {
      final d = connect(
        Object(),
        message: 'bad login with hunter2 in the text',
        password: 'hunter2',
      );
      expect('${d.details} ${d.hint}', isNot(contains('hunter2')));
      expect(d.details, contains('***'));
    });
  });
}
