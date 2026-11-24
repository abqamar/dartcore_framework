import 'package:dartcore_core/dartcore_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseDotEnv', () {
    test('handles quotes, comments, export', () {
      final m = parseDotEnv('''
# comment
APP_NAME=My App # trailing
export A=1
B="line\\nbreak"
C='single # kept'
EMPTY=
bad line
''');
      expect(m['APP_NAME'], 'My App');
      expect(m['A'], '1');
      expect(m['B'], 'line\nbreak');
      expect(m['C'], 'single # kept');
      expect(m['EMPTY'], '');
      expect(m.containsKey('bad line'), isFalse);
    });
  });

  group('ConfigRepository', () {
    test('precedence: override > process env > file values', () async {
      final c = ConfigRepository(environment: {'X': 'env', 'APP_PORT': '9000'});
      expect(c.get('X'), 'env');
      c.set('X', 'override');
      expect(c.get('X'), 'override');
      expect(c.getInt('APP_PORT'), 9000);
      expect(c.getInt('MISSING', 5), 5);
    });

    test('typed getters throw on malformed values', () {
      final c = ConfigRepository(environment: {'B': 'maybe', 'I': 'x'});
      expect(() => c.getBool('B'), throwsA(isA<ConfigurationException>()));
      expect(() => c.getInt('I'), throwsA(isA<ConfigurationException>()));
      expect(() => c.require('NOPE'), throwsA(isA<ConfigurationException>()));
    });

    test('environment parsing defaults to production for unknown', () {
      expect(AppEnvironment.parse('dev'), AppEnvironment.development);
      expect(AppEnvironment.parse('typo'), AppEnvironment.production);
    });
  });

  test('exceptions carry HTTP status codes', () {
    expect(
      ValidationException({
        'a': ['b'],
      }).statusCode,
      422,
    );
    expect(NotFoundException().statusCode, 404);
    expect(AuthenticationException().statusCode, 401);
  });

  group('exception details', () {
    test('toString is unchanged without details or hint', () {
      expect(QueryException('boom').toString(), 'QueryException: boom');
    });

    test('toString appends details and hint', () {
      final e = QueryException(
        'Database query failed (42P07).',
        details: 'relation "users" already exists',
        hint: 'Run migrations',
        code: '42P07',
      );
      expect(e.message, 'Database query failed (42P07).');
      expect(
        e.toString(),
        'QueryException: Database query failed (42P07).\n'
        '  Details: relation "users" already exists\n'
        '  Hint: Run migrations',
      );
    });

    test('all database/config exceptions accept details and hint', () {
      for (final e in <DartCoreException>[
        ConfigurationException('m', details: 'd', hint: 'h'),
        DatabaseException('m', details: 'd', hint: 'h'),
        ConnectionException('m', details: 'd', hint: 'h'),
        QueryException('m', details: 'd', hint: 'h'),
      ]) {
        expect(e.details, 'd');
        expect(e.hint, 'h');
      }
    });
  });
}
