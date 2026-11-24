/// A database row keyed by column name.
typedef Row = Map<String, Object?>;

/// SQL plus ordered bindings, ready for an adapter. [sql] uses the dialect's
/// native placeholder style (`$1`, `?`, `@p1`).
class CompiledQuery {
  const CompiledQuery(this.sql, [this.bindings = const []]);

  final String sql;
  final List<Object?> bindings;

  @override
  String toString() => 'CompiledQuery($sql, ${bindings.length} bindings)';
}

class QueryResult {
  const QueryResult({
    this.rows = const [],
    this.affectedRows = 0,
    this.insertId,
  });

  final List<Row> rows;
  final int affectedRows;

  /// Auto-generated id of the last inserted row, if the driver reports one
  /// (MySQL, SQLite). PostgreSQL/MSSQL return rows via RETURNING/OUTPUT.
  final int? insertId;
}
