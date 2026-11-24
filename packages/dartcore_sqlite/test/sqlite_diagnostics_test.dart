import 'package:dartcore_sqlite/src/sqlite_diagnostics.dart';
import 'package:test/test.dart';

void main() {
  SqliteDiagnosis d(int code, String m) =>
      diagnoseSqliteError(resultCode: code, message: m);

  test('maps common messages to hints and keeps the real message', () {
    expect(d(1, 'table users already exists').hint, contains('already exists'));
    expect(d(1, 'no such table: users').hint, contains('migrations'));
    expect(d(1, 'no such column: x').hint, contains('column'));
    expect(
      d(19, 'UNIQUE constraint failed: users.email').hint,
      contains('Unique'),
    );
    expect(
      d(19, 'NOT NULL constraint failed: users.name').hint,
      contains('Not-null'),
    );
    expect(
      d(19, 'FOREIGN KEY constraint failed').hint,
      contains('Foreign key'),
    );
    expect(d(5, 'database is locked').hint, contains('locked'));
    expect(d(1, 'odd').hint, isNull);
    expect(
      d(19, 'UNIQUE constraint failed: users.email').details,
      allOf(contains('[19]'), contains('users.email')),
    );
  });

  test('open errors', () {
    expect(diagnoseSqliteOpenError(14, '/x/y.db'), contains('writable'));
    expect(diagnoseSqliteOpenError(26, 'f'), contains('not a SQLite'));
  });
}
