import 'dart:async';
import 'dart:io';

import 'package:dartcore_postgres/src/postgres_diagnostics.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

PgDiagnosis conn(Object e, {String? sqlState, String? password}) =>
    diagnosePostgresConnectError(
      e,
      host: 'localhost',
      port: 5432,
      database: 'appdb',
      username: 'bob',
      password: password,
      sqlState: sqlState,
    );

void main() {
  group('query errors', () {
    test('42P07 keeps the real message and explains migrations', () {
      final d = diagnosePostgresQueryError(
        sqlState: '42P07',
        message: 'relation "users" already exists',
      );
      expect(d.details, contains('relation "users" already exists'));
      expect(d.details, contains('42P07'));
      expect(d.hint, contains('migrations'));
    });

    test('includes detail, table, column and constraint', () {
      final d = diagnosePostgresQueryError(
        sqlState: '23505',
        message: 'duplicate key value violates unique constraint "u_email"',
        detail: 'Key (email)=(a@b.c) already exists.',
        schemaName: 'public',
        tableName: 'users',
        columnName: 'email',
        constraintName: 'u_email',
      );
      expect(d.details, contains('Key (email)=(a@b.c) already exists.'));
      expect(d.details, contains('table: users'));
      expect(d.details, contains('column: email'));
      expect(d.details, contains('constraint: u_email'));
      expect(d.hint, contains('Unique'));
    });

    test('common SQLSTATE hints', () {
      String? h(String c) =>
          diagnosePostgresQueryError(sqlState: c, message: 'm').hint;
      expect(h('42501'), allOf(contains('GRANT'), contains('ownership')));
      expect(h('23503'), contains('Foreign key'));
      expect(h('23502'), contains('Not-null'));
      expect(h('42P01'), contains('migrations'));
      expect(h('42703'), contains('column'));
      expect(h('3D000'), contains('database'));
      expect(h('28P01'), contains('password'));
      expect(h('XX999'), isNull);
    });
  });

  group('connect errors', () {
    test('connection refused', () {
      final d = conn(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        ),
      );
      expect(d.hint, contains('not listening on localhost:5432'));
      expect(d.hint, contains('127.0.0.1'));
      expect(d.details, contains('Connection refused'));
    });

    test('DNS failure', () {
      final d = conn(const SocketException('Failed host lookup: \'nope\''));
      expect(d.hint, contains('could not be resolved'));
    });

    test('timeout', () {
      expect(conn(TimeoutException('x')).hint, contains('Timed out'));
    });

    test('authentication failed, password is redacted', () {
      final d = conn(
        pg.PgException('password authentication failed for user "bob" s3cret'),
        sqlState: '28P01',
        password: 's3cret',
      );
      expect(d.hint, contains('Authentication failed'));
      expect(d.details, contains('28P01'));
      expect('${d.details} ${d.hint}', isNot(contains('s3cret')));
    });

    test('database does not exist', () {
      final d = conn(
        pg.PgException('database "appdb" does not exist'),
        sqlState: '3D000',
      );
      expect(d.hint, contains('"appdb" does not exist'));
    });

    test('role does not exist', () {
      final d = conn(
        pg.PgException('role "bob" does not exist'),
        sqlState: '28000',
      );
      expect(d.hint, contains('Role "bob" does not exist'));
    });

    test('SSL', () {
      final d = conn(pg.PgException('server does not support SSL'));
      expect(d.hint, contains('SslMode'));
    });

    test('unknown error still carries the raw reason', () {
      final d = conn(StateError('weird'));
      expect(d.details, contains('weird'));
      expect(d.hint, isNotNull);
    });
  });
}
