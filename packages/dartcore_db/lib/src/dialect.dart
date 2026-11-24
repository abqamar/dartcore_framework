/// SQL syntax differences between database engines.
abstract class SqlDialect {
  const SqlDialect();

  String get name;

  /// Quotes a single identifier part. Callers must validate first; quoting is
  /// defence in depth, not a substitute for validation.
  String quote(String identifier);

  /// Placeholder for the [index]th (1-based) binding.
  String placeholder(int index);

  /// Whether INSERT can return the inserted row (RETURNING / OUTPUT).
  bool get supportsReturning;

  bool get supportsIlike => false;

  /// Maximum bound parameters per statement, used to chunk bulk inserts.
  int get maxParameters;

  String get beginSql => 'BEGIN';
  String get commitSql => 'COMMIT';
  String get rollbackSql => 'ROLLBACK';

  String savepointSql(String name) => 'SAVEPOINT $name';

  /// `null` when the engine has no RELEASE SAVEPOINT.
  String? releaseSavepointSql(String name) => 'RELEASE SAVEPOINT $name';
  String rollbackToSavepointSql(String name) => 'ROLLBACK TO SAVEPOINT $name';

  String truncateSql(String quotedTable) => 'TRUNCATE TABLE $quotedTable';

  /// Compiles LIMIT/OFFSET. [hasOrder] matters for MSSQL.
  String limitOffset(int? limit, int? offset, {required bool hasOrder});

  /// Text placed between the column list and VALUES for INSERT (MSSQL OUTPUT).
  String insertOutput() => '';

  /// Text appended after INSERT statements (RETURNING).
  String insertReturning() => '';
}

class PostgresDialect extends SqlDialect {
  const PostgresDialect();
  @override
  String get name => 'postgres';
  @override
  String quote(String i) => '"${i.replaceAll('"', '""')}"';
  @override
  String placeholder(int index) => '\$$index';
  @override
  bool get supportsReturning => true;
  @override
  bool get supportsIlike => true;
  @override
  int get maxParameters => 65535;
  @override
  String insertReturning() => ' RETURNING *';
  @override
  String limitOffset(int? limit, int? offset, {required bool hasOrder}) =>
      '${limit != null ? ' LIMIT $limit' : ''}${offset != null ? ' OFFSET $offset' : ''}';
}

class MySqlDialect extends SqlDialect {
  const MySqlDialect();
  @override
  String get name => 'mysql';
  @override
  String quote(String i) => '`${i.replaceAll('`', '``')}`';
  @override
  String placeholder(int index) => '?';
  @override
  bool get supportsReturning => false;
  @override
  int get maxParameters => 65535;
  @override
  String get beginSql => 'START TRANSACTION';
  @override
  String limitOffset(int? limit, int? offset, {required bool hasOrder}) {
    if (limit == null && offset == null) return '';
    // MySQL requires LIMIT whenever OFFSET is used.
    return ' LIMIT ${limit ?? '18446744073709551615'}${offset != null ? ' OFFSET $offset' : ''}';
  }
}

class SqliteDialect extends SqlDialect {
  const SqliteDialect();
  @override
  String get name => 'sqlite';
  @override
  String quote(String i) => '"${i.replaceAll('"', '""')}"';
  @override
  String placeholder(int index) => '?';
  // RETURNING needs SQLite >= 3.35 (bundled by package:sqlite3).
  @override
  bool get supportsReturning => true;
  @override
  int get maxParameters => 32766;
  @override
  String insertReturning() => ' RETURNING *';

  /// SQLite has no TRUNCATE; DELETE without WHERE is the documented
  /// equivalent (autoincrement counters are not reset).
  @override
  String truncateSql(String quotedTable) => 'DELETE FROM $quotedTable';
  @override
  String limitOffset(int? limit, int? offset, {required bool hasOrder}) {
    if (limit == null && offset == null) return '';
    return ' LIMIT ${limit ?? -1}${offset != null ? ' OFFSET $offset' : ''}';
  }
}

class MssqlDialect extends SqlDialect {
  const MssqlDialect();
  @override
  String get name => 'mssql';
  @override
  String quote(String i) => '[${i.replaceAll(']', ']]')}]';
  @override
  String placeholder(int index) => '@p$index';
  @override
  bool get supportsReturning => true;
  @override
  int get maxParameters => 2100;
  @override
  String get beginSql => 'BEGIN TRANSACTION';
  @override
  String get commitSql => 'COMMIT TRANSACTION';
  @override
  String get rollbackSql => 'ROLLBACK TRANSACTION';
  @override
  String savepointSql(String name) => 'SAVE TRANSACTION $name';
  @override
  String? releaseSavepointSql(String name) => null;
  @override
  String rollbackToSavepointSql(String name) => 'ROLLBACK TRANSACTION $name';
  @override
  String insertOutput() => ' OUTPUT INSERTED.*';
  @override
  String limitOffset(int? limit, int? offset, {required bool hasOrder}) {
    if (limit == null && offset == null) return '';
    final order = hasOrder ? '' : ' ORDER BY (SELECT NULL)';
    return '$order OFFSET ${offset ?? 0} ROWS'
        '${limit != null ? ' FETCH NEXT $limit ROWS ONLY' : ''}';
  }
}
