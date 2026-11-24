// SQLite adapter with an in-memory database (ran for real).
//
// Observed output of `dart run example/dartcore_sqlite_example.dart`:
//
//   inserted: {id: 1, name: Alice, age: 30}
//   adults: [Alice, Carol]
//   count: 3
//   after rollback, Alice exists: true
//   page 1: 2 rows of 3, meta={current_page: 1, per_page: 2, total: 3, last_page: 2, has_next_page: true, has_previous_page: false}

import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

Future<void> main() async {
  registerSqlite();
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');

  await DB.statement(
    'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, '
    'name TEXT NOT NULL, age INTEGER)',
  );

  final alice = await DB.table('users').insert({'name': 'Alice', 'age': 30});
  print('inserted: $alice');
  await DB.table('users').insertMany([
    {'name': 'Bob', 'age': 17},
    {'name': 'Carol', 'age': 41},
  ]);

  final adults = await DB
      .table('users')
      .where('age', '>=', 18)
      .orderBy('name')
      .get();
  print('adults: ${adults.map((r) => r['name']).toList()}');
  print('count: ${await DB.table('users').count()}');

  // Transactions roll back on any exception.
  try {
    await DB.transaction((tx) async {
      await tx.table('users').where('name', 'Alice').delete();
      throw StateError('boom');
    });
  } on StateError {
    print(
      'after rollback, Alice exists: '
      '${await DB.table('users').where('name', 'Alice').exists()}',
    );
  }

  final page = await DB
      .table('users')
      .orderBy('id')
      .paginate(page: 1, limit: 2);
  print('page 1: ${page.data.length} rows of ${page.total}, meta=${page.meta}');

  await DB.reset();
}
