// Query builder compiled for four SQL dialects (no database needed; a printing executor stands in).
//
// Observed output of `dart run example/dartcore_db_example.dart`:
//
//   postgres:
//     SELECT "id", "name" FROM "users" WHERE "status" = $1 AND "age" >= $2 AND "role" IN ($3, $4) ORDER BY "created_at" DESC LIMIT 20 OFFSET 40   bindings=[active, 18, admin, editor]
//   mysql:
//     SELECT `id`, `name` FROM `users` WHERE `status` = ? AND `age` >= ? AND `role` IN (?, ?) ORDER BY `created_at` DESC LIMIT 20 OFFSET 40   bindings=[active, 18, admin, editor]
//   sqlite:
//     SELECT "id", "name" FROM "users" WHERE "status" = ? AND "age" >= ? AND "role" IN (?, ?) ORDER BY "created_at" DESC LIMIT 20 OFFSET 40   bindings=[active, 18, admin, editor]
//   mssql:
//     SELECT [id], [name] FROM [users] WHERE [status] = @p1 AND [age] >= @p2 AND [role] IN (@p3, @p4) ORDER BY [created_at] DESC OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY   bindings=[active, 18, admin, editor]
//   update without where -> QueryException
//   bad identifier -> QueryException

import 'package:dartcore_db/dartcore_db.dart';

class PrintingExecutor implements DatabaseExecutor {
  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    print('  ${query.sql}   bindings=${query.bindings}');
    return const QueryResult();
  }
}

Future<void> main() async {
  final dialects = <SqlDialect>[
    const PostgresDialect(),
    const MySqlDialect(),
    const SqliteDialect(),
    const MssqlDialect(),
  ];

  for (final dialect in dialects) {
    print('${dialect.name}:');
    await QueryBuilder(PrintingExecutor(), dialect, 'users')
        .select(['id', 'name'])
        .where('status', 'active')
        .where('age', '>=', 18)
        .whereIn('role', ['admin', 'editor'])
        .orderBy('created_at', descending: true)
        .limit(20)
        .offset(40)
        .get();
  }

  // Safety rules: updates without a WHERE are refused, bad identifiers throw.
  final users = QueryBuilder(
    PrintingExecutor(),
    const SqliteDialect(),
    'users',
  );
  try {
    await users.update({'active': false});
  } on Object catch (e) {
    print('update without where -> ${e.runtimeType}');
  }
  try {
    await QueryBuilder(
      PrintingExecutor(),
      const SqliteDialect(),
      'users; DROP',
    ).get();
  } on Object catch (e) {
    print('bad identifier -> ${e.runtimeType}');
  }
}
