import 'dart:convert';
import 'dart:typed_data';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mssql/dartcore_mssql.dart';
import 'package:mssql_dart/mssql_dart.dart' as mssql;
import 'package:test/test.dart';

/// A connection whose "driver" just records the call and returns [result].
(SqlServerConnection, List<(String, Map<String, Object?>?)>) fake([
  RawResult result = const RawResult([], 0),
]) {
  final calls = <(String, Map<String, Object?>?)>[];
  final c = SqlServerConnection.forTesting((sql, params) async {
    calls.add((sql, params));
    return result;
  });
  return (c, calls);
}

SqlServerConnection failing(Object error) =>
    SqlServerConnection.forTesting((_, _) async => throw error);

T serverError<T extends mssql.DatabaseException>(T e, int number) {
  e.number = number;
  e.severity = 16;
  e.state = 1;
  return e;
}

void main() {
  group('parameters', () {
    test('bindings become named p1..pn matching @p1..@pn', () async {
      final (c, calls) = fake();
      await c.execute(
        const CompiledQuery('SELECT * FROM t WHERE a = @p1 AND b = @p2', [
          1,
          'x',
        ]),
      );
      expect(calls.single.$1, 'SELECT * FROM t WHERE a = @p1 AND b = @p2');
      expect(calls.single.$2, {'p1': 1, 'p2': 'x'});
    });

    test('no bindings sends no parameters (plain batch)', () async {
      final (c, calls) = fake();
      await c.execute(const CompiledQuery('BEGIN TRANSACTION'));
      expect(calls.single.$2, isNull);
    });

    test('value conversion', () {
      expect(SqlServerConnection.toParameter(null), isNull);
      expect(SqlServerConnection.toParameter(5), 5);
      expect(SqlServerConnection.toParameter(1.5), 1.5);
      expect(SqlServerConnection.toParameter(true), true);
      expect(SqlServerConnection.toParameter('é'), 'é');
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(SqlServerConnection.toParameter(bytes), same(bytes));
      expect(SqlServerConnection.toParameter(BigInt.two), BigInt.two);
      expect(
        SqlServerConnection.toParameter(const Duration(hours: 1)),
        const Duration(hours: 1),
      );
      expect(SqlServerConnection.toParameter({'a': 1}), jsonEncode({'a': 1}));
      expect(SqlServerConnection.toParameter([1, 2]), '[1,2]');
      expect(SqlServerConnection.toParameter(Uri.parse('x:y')), 'x:y');
    });

    test('a local DateTime is sent as its UTC calendar fields', () {
      final local = DateTime(2026, 5, 17, 10, 30);
      final sent = SqlServerConnection.toParameter(local)! as DateTime;
      expect(sent.isUtc, isTrue);
      expect(sent, local.toUtc());
      final utc = DateTime.utc(2026, 1, 1);
      expect(SqlServerConnection.toParameter(utc), utc);
    });
  });

  group('results', () {
    test(
      'rows and affected rows are converted; negative counts become 0',
      () async {
        final (c, _) = fake(
          RawResult([
            {
              'id': 7,
              'price': mssql.DecimalValue.parse('12.50'),
              'at': DateTime.utc(2026, 1, 2),
            },
          ], -1),
        );
        final r = await c.execute(const CompiledQuery('SELECT 1'));
        expect(r.affectedRows, 0);
        expect(r.rows.single, {
          'id': 7,
          'price': 12.5,
          'at': DateTime.utc(2026, 1, 2),
        });
      },
    );

    test('decimals: whole numbers become int, huge values stay text', () {
      expect(SqlServerConnection.fromValue(mssql.DecimalValue.parse('42')), 42);
      expect(
        SqlServerConnection.fromValue(
          mssql.DecimalValue.parse('123456789012345678901234567890.12'),
        ),
        '123456789012345678901234567890.12',
      );
    });

    test(
      'datetimeoffset becomes its UTC instant; unknown types become text',
      () {
        final at = DateTime.utc(2026, 3, 4, 5, 6);
        expect(
          SqlServerConnection.fromValue(
            mssql.DateTimeOffsetValue(utc: at, offsetMinutes: 120),
          ),
          at,
        );
        expect(SqlServerConnection.fromValue(Uri.parse('x:y')), 'x:y');
        expect(SqlServerConnection.fromValue(null), isNull);
        expect(SqlServerConnection.fromValue(false), false);
      },
    );
  });

  group('errors', () {
    test(
      'a server error becomes a QueryException with number, details, hint',
      () async {
        final c = failing(
          serverError(
            mssql.IntegrityException('Violation of UNIQUE KEY'),
            2627,
          ),
        );
        final e = await c
            .execute(const CompiledQuery('INSERT ...'))
            .then<Object>((_) => 'no error', onError: (Object e) => e);
        expect(e, isA<QueryException>());
        e as QueryException;
        expect(e.code, '2627');
        expect(e.message, contains('SQL Server 2627'));
        expect(e.sql, 'INSERT ...');
        expect(e.details, contains('Violation of UNIQUE KEY'));
        expect(e.details, contains('severity 16'));
        expect(e.hint, contains('already exists'));
      },
    );

    test('missing table maps to a hint about migrations', () async {
      final c = failing(
        serverError(
          mssql.ProgrammingException("Invalid object name 'dbo.tasks'."),
          208,
        ),
      );
      await expectLater(
        c.execute(const CompiledQuery('SELECT * FROM tasks')),
        throwsA(
          isA<QueryException>().having(
            (e) => e.hint,
            'hint',
            contains('migrations'),
          ),
        ),
      );
    });

    test('a timeout is a QueryException, not a connection error', () async {
      final c = failing(
        mssql.MssqlTimeoutException(const Duration(seconds: 5)),
      );
      await expectLater(
        c.execute(const CompiledQuery('SELECT 1')),
        throwsA(isA<QueryException>()),
      );
    });

    test('network-level driver errors are ConnectionExceptions', () async {
      for (final error in <Object>[
        mssql.OperationalException('socket closed'),
        mssql.ClosedConnectionException(),
        mssql.InterfaceException('connection is closed'),
      ]) {
        await expectLater(
          failing(error).execute(const CompiledQuery('SELECT 1')),
          throwsA(isA<ConnectionException>()),
          reason: '$error',
        );
      }
    });

    test('a bad parameter value is a QueryException', () async {
      await expectLater(
        failing(
          mssql.DataException('value out of range'),
        ).execute(const CompiledQuery('SELECT @p1', [1])),
        throwsA(
          isA<QueryException>().having(
            (e) => e.details,
            'details',
            contains('out of range'),
          ),
        ),
      );
    });

    test('bound values never appear in the exception', () async {
      final c = failing(
        serverError(mssql.IntegrityException('Violation of UNIQUE KEY'), 2627),
      );
      try {
        await c.execute(
          const CompiledQuery('INSERT INTO u (email) VALUES (@p1)', [
            'secret-value@example.com',
          ]),
        );
        fail('expected an exception');
      } on QueryException catch (e) {
        expect(
          '$e ${e.details} ${e.hint} ${e.sql}',
          isNot(contains('secret-value')),
        );
      }
    });
  });

  group('connection', () {
    test('ping and isOpen', () async {
      final (c, _) = fake();
      expect(await c.ping(), isTrue);
      expect(c.isOpen, isTrue);
      expect(await failing(StateError('x')).ping(), isFalse);
    });

    test('close runs the close hook and never throws', () async {
      var closed = false;
      final c = SqlServerConnection.forTesting(
        (_, _) async => const RawResult([], 0),
        onClose: () async => closed = true,
      );
      await c.close();
      expect(closed, isTrue);
    });
  });

  group('settings', () {
    ConnectionConfig cfg({
      SslMode ssl = SslMode.disable,
      Map<String, Object?> o = const {},
      int? port,
    }) => ConnectionConfig(
      driver: DatabaseDriver.mssql,
      host: 'db.example.com',
      port: port,
      database: 'app',
      username: 'sa',
      password: 'pw',
      ssl: ssl,
      options: o,
    );

    test('defaults', () {
      final s = SqlServerConnection.settingsFor(cfg());
      expect(s.host, 'db.example.com');
      expect(s.port, 1433);
      expect(s.database, 'app');
      expect(s.username, 'sa');
      expect(s.applicationName, 'dartcore');
    });

    test('ssl disable sends everything unencrypted', () {
      final s = SqlServerConnection.settingsFor(cfg());
      expect(s.encrypt, isFalse);
    });

    test('ssl require encrypts without verifying the certificate', () {
      final s = SqlServerConnection.settingsFor(cfg(ssl: SslMode.require));
      expect(s.encrypt, isTrue);
      expect(s.trustServerCertificate, isTrue);
    });

    test('ssl verifyFull verifies the certificate', () {
      final s = SqlServerConnection.settingsFor(
        cfg(ssl: SslMode.verifyFull, o: {'ca_file': '/etc/ssl/ca.pem'}),
      );
      expect(s.encrypt, isTrue);
      expect(s.trustServerCertificate, isFalse);
      expect(s.caFile, '/etc/ssl/ca.pem');
    });

    test('a named instance drops the port so the Browser is asked', () {
      final s = SqlServerConnection.settingsFor(
        cfg(o: {'instance': 'SQLEXPRESS'}),
      );
      expect(s.instanceName, 'SQLEXPRESS');
      expect(s.port, isNull);
    });

    test('other options', () {
      final s = SqlServerConnection.settingsFor(
        cfg(
          o: {'application_name': 'api', 'read_only_intent': true},
          port: 14330,
        ),
      );
      expect(s.applicationName, 'api');
      expect(s.readOnlyIntent, isTrue);
      expect(s.port, 14330);
    });
  });

  group('registration and a real (failing) connect', () {
    test(
      'registerMssql lets DB.connect run and report a refused port',
      () async {
        registerMssql();
        final manager = DatabaseManager();
        await expectLater(
          manager.connect(
            const ConnectionConfig(
              driver: DatabaseDriver.mssql,
              host: '127.0.0.1',
              port: 1, // nothing listens here
              database: 'app',
              username: 'sa',
              password: 'super-secret-password',
              connectTimeout: Duration(seconds: 3),
            ),
          ),
          throwsA(
            isA<ConnectionException>()
                .having((e) => e.details, 'details', isNotNull)
                .having((e) => e.hint, 'hint', contains('listening'))
                .having((e) => e.hint, 'hint', contains('127.0.0.1:1'))
                .having(
                  (e) => '${e.details} ${e.hint} ${e.message}',
                  'text',
                  isNot(contains('super-secret-password')),
                ),
          ),
        );
      },
    );
  });
}
