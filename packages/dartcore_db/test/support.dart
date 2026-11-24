import 'package:dartcore_db/dartcore_db.dart';

/// Records compiled queries and replies with canned results.
class RecordingExecutor implements DatabaseExecutor {
  final List<CompiledQuery> queries = [];
  QueryResult Function(CompiledQuery q)? reply;

  @override
  Future<QueryResult> execute(CompiledQuery query) async {
    queries.add(query);
    return reply?.call(query) ?? const QueryResult();
  }

  CompiledQuery get last => queries.last;
}

const dialects = <SqlDialect>[
  PostgresDialect(),
  MySqlDialect(),
  SqliteDialect(),
  MssqlDialect(),
];

QueryBuilder qb(SqlDialect d, String table, [RecordingExecutor? e]) =>
    QueryBuilder(e ?? RecordingExecutor(), d, table);
