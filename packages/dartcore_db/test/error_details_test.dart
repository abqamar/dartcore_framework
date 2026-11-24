import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:test/test.dart';

void main() {
  test('connection failures keep details and hint through the manager', () {
    final original = ConnectionException(
      'Could not connect to PostgreSQL at localhost:5432.',
      details: '[28P01] password authentication failed for user "x"',
      hint: 'Check the username and password.',
    );
    final manager = DatabaseManager(
      drivers: {
        DatabaseDriver.postgres: DriverRegistration(
          dialect: const PostgresDialect(),
          capabilities: const AdapterCapabilities(returning: true),
          open: (_) async => throw original,
        ),
      },
    );
    expect(
      manager.connect(
        const ConnectionConfig(driver: DatabaseDriver.postgres, database: 'd'),
      ),
      throwsA(
        isA<ConnectionException>()
            .having((e) => e.details, 'details', contains('28P01'))
            .having((e) => e.hint, 'hint', contains('password'))
            .having((e) => e.toString(), 'toString', contains('Hint:')),
      ),
    );
  });
}
