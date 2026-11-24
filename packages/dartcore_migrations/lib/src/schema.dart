import 'dart:async';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';

import 'blueprint.dart';

/// Compiles blueprints to dialect-specific DDL and runs it.
///
/// Inside a migration use the static facade (`Schema.create(...)`); the
/// migrator binds it to the right connection. Outside a migration it uses the
/// default `DB` connection.
class SchemaBuilder {
  SchemaBuilder(this.db);

  final DatabaseOperations db;
  SqlDialect get _d => db.dialect;

  String _q(String ident) => Identifier.quote(_d, ident);

  // ---- public operations ---------------------------------------------------

  Future<void> create(String table, void Function(Blueprint t) build) async {
    final bp = Blueprint(table);
    build(bp);
    await _run(compileCreate(bp));
  }

  Future<void> table(String table, void Function(Blueprint t) build) async {
    final bp = Blueprint(table);
    build(bp);
    await _run(compileAlter(bp));
  }

  Future<void> drop(String table) => db.statement('DROP TABLE ${_q(table)}');
  Future<void> dropIfExists(String table) =>
      db.statement('DROP TABLE IF EXISTS ${_q(table)}');
  Future<void> rename(String from, String to) async {
    await db.statement(
      _d is MssqlDialect
          ? "EXEC sp_rename '${_q(from)}', '$to'"
          : _d is MySqlDialect
          ? 'RENAME TABLE ${_q(from)} TO ${_q(to)}'
          : 'ALTER TABLE ${_q(from)} RENAME TO ${_q(to)}',
    );
  }

  Future<bool> hasTable(String table) async {
    final d = _d;
    final List<Row> rows;
    if (d is SqliteDialect) {
      rows = await db.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table],
      );
    } else if (d is MySqlDialect) {
      rows = await db.select(
        'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?',
        [table],
      );
    } else if (d is MssqlDialect) {
      rows = await db.select(
        'SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = ?',
        [table],
      );
    } else {
      rows = await db.select(
        'SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?',
        [table],
      );
    }
    return rows.isNotEmpty;
  }

  Future<bool> hasColumn(String table, String column) async {
    final d = _d;
    if (d is SqliteDialect) {
      final rows = await db.select('PRAGMA table_info(${_q(table)})');
      return rows.any((r) => r['name'] == column);
    }
    final where = d is MySqlDialect
        ? 'table_schema = DATABASE()'
        : d is MssqlDialect
        ? '1 = 1'
        : 'table_schema = current_schema()';
    final rows = await db.select(
      'SELECT 1 FROM information_schema.columns WHERE $where AND table_name = ? AND column_name = ?',
      [table, column],
    );
    return rows.isNotEmpty;
  }

  /// Names of all user tables in the current database/schema.
  Future<List<String>> tables() async {
    final d = _d;
    final sql = d is SqliteDialect
        ? "SELECT name AS n FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        : d is MySqlDialect
        ? 'SELECT table_name AS n FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = \'BASE TABLE\''
        : d is MssqlDialect
        ? 'SELECT name AS n FROM sys.tables'
        : 'SELECT table_name AS n FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = \'BASE TABLE\'';
    return [
      for (final r in await db.select(sql))
        (r['n'] ?? r['N'] ?? r.values.first).toString(),
    ];
  }

  Future<void> _run(List<String> statements) async {
    for (final s in statements) {
      await db.statement(s);
    }
  }

  // ---- compilation ------------------------------------------------------------

  List<String> compileCreate(Blueprint bp) {
    final lines = <String>[]; // column definitions
    final constraints = <String>[]; // table constraints must follow all columns
    final after = <String>[];
    final pkCols = bp.compositePrimary;
    for (final c in bp.columns) {
      lines.add(_columnSql(c, inlinePk: pkCols == null));
      if (c.isIndexed) {
        after.add(_indexSql(bp.table, IndexDefinition([c.name])));
      }
      if (c.fkTable != null) {
        constraints.add(
          _fkSql(
            bp.table,
            c.name,
            c.fkTable!,
            c.fkColumn!,
            c.fkOnDelete,
            c.fkOnUpdate,
          ),
        );
      }
    }
    if (pkCols != null) {
      constraints.add('PRIMARY KEY (${pkCols.map(_q).join(', ')})');
    }
    for (final f in bp.foreignKeys) {
      if (f.table == null) {
        throw StateError('foreign(${f.column}) needs references(table).');
      }
      constraints.add(
        _fkSql(
          bp.table,
          f.column,
          f.table!,
          f.refColumn!,
          f.onDeleteAction,
          f.onUpdateAction,
        ),
      );
    }
    for (final i in bp.indexes) {
      if (i.unique) {
        constraints.add(
          'CONSTRAINT ${_q(_indexName(bp.table, i))} UNIQUE (${i.columns.map(_q).join(', ')})',
        );
      } else {
        after.add(_indexSql(bp.table, i));
      }
    }
    return [
      'CREATE TABLE ${_q(bp.table)} (\n  ${[...lines, ...constraints].join(',\n  ')}\n)',
      ...after,
    ];
  }

  List<String> compileAlter(Blueprint bp) {
    final out = <String>[];
    final t = _q(bp.table);
    // Drop dependents (foreign keys, indexes) before columns they reference.
    for (final f in bp.dropForeign) {
      out.add(
        _d is MySqlDialect
            ? 'ALTER TABLE $t DROP FOREIGN KEY ${_q(f)}'
            : 'ALTER TABLE $t DROP CONSTRAINT ${_q(f)}',
      );
    }
    for (final i in bp.dropIndexes) {
      out.add(
        _d is MySqlDialect || _d is MssqlDialect
            ? 'DROP INDEX ${_q(i)} ON $t'
            : 'DROP INDEX ${_q(i)}',
      );
    }
    for (final c in bp.columns) {
      if (c.isChange) {
        out.addAll(_modify(bp.table, c));
        continue;
      }
      // SQLite cannot add UNIQUE / PRIMARY KEY / FK columns via ALTER ADD COLUMN.
      if (_d is SqliteDialect && (c.isUnique || c.fkTable != null)) {
        throw UnsupportedError(
          'SQLite cannot add a UNIQUE or foreign-key column to an existing table. '
          'Create the column first and add a separate unique index, or recreate the table.',
        );
      }
      out.add(
        'ALTER TABLE $t ${_d is MssqlDialect ? 'ADD' : 'ADD COLUMN'} ${_columnSql(c, inlinePk: true)}',
      );
      if (c.fkTable != null) {
        out.add(
          'ALTER TABLE $t ADD ${_fkSql(bp.table, c.name, c.fkTable!, c.fkColumn!, c.fkOnDelete, c.fkOnUpdate)}',
        );
      }
      if (c.isIndexed) out.add(_indexSql(bp.table, IndexDefinition([c.name])));
    }
    for (final e in bp.renameColumns.entries) {
      out.add(
        _d is MssqlDialect
            ? "EXEC sp_rename '${bp.table}.${e.key}', '${e.value}', 'COLUMN'"
            : 'ALTER TABLE $t RENAME COLUMN ${_q(e.key)} TO ${_q(e.value)}',
      );
    }
    for (final c in bp.dropColumns) {
      out.add('ALTER TABLE $t DROP COLUMN ${_q(c)}');
    }
    for (final i in bp.indexes) {
      out.add(
        i.unique
            ? 'CREATE UNIQUE INDEX ${_q(_indexName(bp.table, i))} ON $t (${i.columns.map(_q).join(', ')})'
            : _indexSql(bp.table, i),
      );
    }
    for (final f in bp.foreignKeys) {
      if (_d is SqliteDialect) {
        throw UnsupportedError(
          'SQLite cannot add a foreign key to an existing table.',
        );
      }
      out.add(
        'ALTER TABLE $t ADD ${_fkSql(bp.table, f.column, f.table!, f.refColumn!, f.onDeleteAction, f.onUpdateAction)}',
      );
    }
    return out;
  }

  List<String> _modify(String table, ColumnDefinition c) {
    final t = _q(table);
    final d = _d;
    if (d is SqliteDialect) {
      throw UnsupportedError(
        'SQLite cannot modify a column in place. Recreate the table (create new, copy, drop, rename).',
      );
    }
    if (d is MySqlDialect) {
      return ['ALTER TABLE $t MODIFY COLUMN ${_columnSql(c, inlinePk: false)}'];
    }
    if (d is MssqlDialect) {
      return [
        'ALTER TABLE $t ALTER COLUMN ${_q(c.name)} ${_type(c)} ${c.isNullable ? 'NULL' : 'NOT NULL'}',
      ];
    }
    final col = _q(c.name);
    return [
      'ALTER TABLE $t ALTER COLUMN $col TYPE ${_type(c)}',
      'ALTER TABLE $t ALTER COLUMN $col ${c.isNullable ? 'DROP NOT NULL' : 'SET NOT NULL'}',
      if (c.hasDefault || c.defaultRaw != null)
        'ALTER TABLE $t ALTER COLUMN $col SET DEFAULT ${_defaultLiteral(c)}',
    ];
  }

  String _columnSql(ColumnDefinition c, {required bool inlinePk}) {
    final d = _d;
    final name = _q(c.name);
    if (c.type == 'id') {
      final pk = d is PostgresDialect
          ? 'BIGSERIAL PRIMARY KEY'
          : d is MySqlDialect
          ? 'BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY'
          : d is SqliteDialect
          ? 'INTEGER PRIMARY KEY AUTOINCREMENT'
          : 'BIGINT IDENTITY(1,1) PRIMARY KEY';
      return '$name $pk';
    }
    final b = StringBuffer('$name ${_type(c)}');
    b.write(c.isNullable ? ' NULL' : ' NOT NULL');
    if (c.hasDefault || c.defaultRaw != null) {
      b.write(' DEFAULT ${_defaultLiteral(c)}');
    }
    if (c.isUnique) b.write(' UNIQUE');
    return b.toString();
  }

  String _type(ColumnDefinition c) {
    final d = _d;
    final pg = d is PostgresDialect,
        my = d is MySqlDialect,
        lite = d is SqliteDialect;
    switch (c.type) {
      case 'foreignId':
        return pg
            ? 'BIGINT'
            : my
            ? 'BIGINT UNSIGNED'
            : lite
            ? 'INTEGER'
            : 'BIGINT';
      case 'string':
        return lite
            ? 'VARCHAR(${c.length})'
            : (pg || my)
            ? 'VARCHAR(${c.length})'
            : 'NVARCHAR(${c.length})';
      case 'text':
        return d is MssqlDialect ? 'NVARCHAR(MAX)' : 'TEXT';
      case 'integer':
        return lite ? 'INTEGER' : 'INT';
      case 'bigInteger':
        return lite ? 'INTEGER' : 'BIGINT';
      case 'boolean':
        return pg
            ? 'BOOLEAN'
            : my
            ? 'TINYINT(1)'
            : lite
            ? 'INTEGER'
            : 'BIT';
      case 'decimal':
        return 'DECIMAL(${c.precision}, ${c.scale})';
      case 'double':
        return pg
            ? 'DOUBLE PRECISION'
            : my
            ? 'DOUBLE'
            : lite
            ? 'REAL'
            : 'FLOAT';
      case 'date':
        return 'DATE';
      case 'dateTime' || 'timestamp':
        return pg
            ? 'TIMESTAMP'
            : my
            ? 'DATETIME'
            : lite
            ? 'DATETIME'
            : 'DATETIME2';
      case 'json':
        return pg
            ? 'JSONB'
            : my
            ? 'JSON'
            : lite
            ? 'TEXT'
            : 'NVARCHAR(MAX)';
      case 'uuid':
        return pg
            ? 'UUID'
            : my
            ? 'CHAR(36)'
            : lite
            ? 'TEXT'
            : 'UNIQUEIDENTIFIER';
      case 'binary':
        return pg
            ? 'BYTEA'
            : my
            ? 'BLOB'
            : lite
            ? 'BLOB'
            : 'VARBINARY(MAX)';
    }
    throw StateError('Unknown column type "${c.type}".');
  }

  String _defaultLiteral(ColumnDefinition c) {
    if (c.defaultRaw != null) return c.defaultRaw!;
    final v = c.defaultVal;
    if (v == null) return 'NULL';
    if (v is bool) {
      return _d is PostgresDialect ? (v ? 'TRUE' : 'FALSE') : (v ? '1' : '0');
    }
    if (v is num) return v.toString();
    return "'${v.toString().replaceAll("'", "''")}'";
  }

  String _indexName(String table, IndexDefinition i) {
    final base =
        i.name ??
        '${table}_${i.columns.join('_')}_${i.unique ? 'unique' : 'index'}';
    return base.length > 63 ? base.substring(0, 63) : base;
  }

  String _indexSql(String table, IndexDefinition i) =>
      'CREATE ${i.unique ? 'UNIQUE ' : ''}INDEX ${_q(_indexName(table, i))} '
      'ON ${_q(table)} (${i.columns.map(_q).join(', ')})';

  static const _fkActions = {
    'cascade',
    'restrict',
    'set null',
    'no action',
    'set default',
  };

  String _fkSql(
    String table,
    String col,
    String refTable,
    String refCol,
    String? onDelete,
    String? onUpdate,
  ) {
    for (final a in [onDelete, onUpdate]) {
      if (a != null && !_fkActions.contains(a.toLowerCase())) {
        throw ArgumentError('Invalid foreign key action "$a".');
      }
    }
    final name = '${table}_${col}_foreign';
    return 'CONSTRAINT ${_q(name.length > 63 ? name.substring(0, 63) : name)} FOREIGN KEY (${_q(col)}) '
        'REFERENCES ${_q(refTable)} (${_q(refCol)})'
        '${onDelete != null ? ' ON DELETE ${onDelete.toUpperCase()}' : ''}'
        '${onUpdate != null ? ' ON UPDATE ${onUpdate.toUpperCase()}' : ''}';
  }
}

const _zoneKey = #dartcoreSchema;

/// Static facade: `await Schema.create('users', (table) {...})`.
abstract final class Schema {
  static SchemaBuilder get _current =>
      (Zone.current[_zoneKey] as SchemaBuilder?) ?? SchemaBuilder(DB.manager);

  /// Runs [body] so that `Schema.*` calls inside use [builder].
  static Future<T> runWith<T>(
    SchemaBuilder builder,
    Future<T> Function() body,
  ) => runZoned(body, zoneValues: {_zoneKey: builder});

  static Future<void> create(String table, void Function(Blueprint t) build) =>
      _current.create(table, build);
  static Future<void> table(String table, void Function(Blueprint t) build) =>
      _current.table(table, build);
  static Future<void> drop(String table) => _current.drop(table);
  static Future<void> dropIfExists(String table) =>
      _current.dropIfExists(table);
  static Future<void> rename(String from, String to) =>
      _current.rename(from, to);
  static Future<bool> hasTable(String table) => _current.hasTable(table);
  static Future<bool> hasColumn(String table, String column) =>
      _current.hasColumn(table, column);
}

/// Thrown for destructive actions that were not confirmed.
class UnconfirmedDestructiveActionException extends DartCoreException {
  UnconfirmedDestructiveActionException(String action)
    : super('Refusing to $action without explicit confirmation.');
}
