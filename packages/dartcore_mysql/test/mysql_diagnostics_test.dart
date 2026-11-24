import 'dart:async';
import 'dart:io';

import 'package:dartcore_mysql/src/mysql_diagnostics.dart';
import 'package:test/test.dart';

MySqlDiagnosis conn(Object e, {int? code, String? message, String? password}) =>
    diagnoseMySqlConnectError(
      e,
      host: 'localhost',
      port: 3306,
      database: 'appdb',
      username: 'bob',
      password: password,
      errorCode: code,
      message: message,
    );

void main() {
  group('query errors', () {
    test('1050 table exists', () {
      final d = diagnoseMySqlQueryError(
        errorCode: 1050,
        message: "Table 'users' already exists",
      );
      expect(d.details, contains("Table 'users' already exists"));
      expect(d.details, contains('1050'));
      expect(d.hint, contains('migration'));
    });

    test('common codes have hints, unknown does not', () {
      String? h(int c) =>
          diagnoseMySqlQueryError(errorCode: c, message: 'm').hint;
      expect(h(1062), contains('Duplicate'));
      expect(h(1451), contains('Foreign key'));
      expect(h(1452), contains('Foreign key'));
      expect(h(1048), contains('Not-null'));
      expect(h(1146), contains('does not exist'));
      expect(h(1054), contains('column'));
      expect(h(1142), contains('GRANT'));
      expect(h(9999), isNull);
    });
  });

  group('connect errors', () {
    test('connection refused', () {
      final d = conn(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      );
      expect(d.hint, contains('not listening on localhost:3306'));
    });

    test('access denied, password redacted', () {
      final d = conn(
        Exception('x'),
        code: 1045,
        message: "Access denied for user 'bob' (using password: s3cret)",
        password: 's3cret',
      );
      expect(d.hint, contains('Access denied'));
      expect('${d.details} ${d.hint}', isNot(contains('s3cret')));
    });

    test('unknown database', () {
      final d = conn(Exception('x'), code: 1049, message: 'Unknown database');
      expect(d.hint, contains('"appdb" does not exist'));
    });

    test('DNS and timeout', () {
      expect(
        conn(const SocketException("Failed host lookup: 'x'")).hint,
        contains('resolved'),
      );
      expect(conn(TimeoutException('t')).hint, contains('Timed out'));
    });
  });
}
