/// A column definition inside a [Blueprint].
class ColumnDefinition {
  ColumnDefinition(
    this.name,
    this.type, {
    this.length,
    this.precision,
    this.scale,
  });

  final String name;

  /// Logical type: id, foreignId, string, text, integer, bigInteger, boolean,
  /// decimal, double, date, dateTime, timestamp, json, uuid, binary.
  final String type;
  final int? length, precision, scale;

  bool isNullable = false;
  bool isUnique = false;
  bool isIndexed = false;
  bool isChange = false;
  bool hasDefault = false;
  Object? defaultVal;
  String? defaultRaw;
  String? fkTable, fkColumn, fkOnDelete, fkOnUpdate;

  ColumnDefinition nullable([bool value = true]) {
    isNullable = value;
    return this;
  }

  ColumnDefinition unique() {
    isUnique = true;
    return this;
  }

  ColumnDefinition index() {
    isIndexed = true;
    return this;
  }

  /// `defaultValue(true)`, `defaultValue('x')`, `defaultValue(0)`.
  ColumnDefinition defaultValue(Object? value) {
    hasDefault = true;
    defaultVal = value;
    return this;
  }

  /// Defaults to the current timestamp.
  ColumnDefinition useCurrent() {
    defaultRaw = 'CURRENT_TIMESTAMP';
    return this;
  }

  /// Foreign key: `table.foreignId('user_id').references('users').onDelete('cascade')`.
  ColumnDefinition references(String table, [String column = 'id']) {
    fkTable = table;
    fkColumn = column;
    return this;
  }

  /// One of `cascade`, `restrict`, `set null`, `no action`.
  ColumnDefinition onDelete(String action) {
    fkOnDelete = action;
    return this;
  }

  ColumnDefinition onUpdate(String action) {
    fkOnUpdate = action;
    return this;
  }

  /// Modify an existing column (ALTER). Not supported by SQLite.
  ColumnDefinition change() {
    isChange = true;
    return this;
  }
}

class IndexDefinition {
  IndexDefinition(this.columns, {this.unique = false, this.name});
  final List<String> columns;
  final bool unique;
  final String? name;
}

class ForeignKeyDefinition {
  ForeignKeyDefinition(this.column);
  final String column;
  String? table, refColumn, onDeleteAction, onUpdateAction;

  ForeignKeyDefinition references(String table, [String column = 'id']) {
    this.table = table;
    refColumn = column;
    return this;
  }

  ForeignKeyDefinition onDelete(String a) {
    onDeleteAction = a;
    return this;
  }

  ForeignKeyDefinition onUpdate(String a) {
    onUpdateAction = a;
    return this;
  }
}

/// Describes a table. Used by `Schema.create` and `Schema.table`.
class Blueprint {
  Blueprint(this.table);
  final String table;

  final List<ColumnDefinition> columns = [];
  final List<IndexDefinition> indexes = [];
  final List<ForeignKeyDefinition> foreignKeys = [];
  final List<String> dropColumns = [];
  final Map<String, String> renameColumns = {};
  final List<String> dropIndexes = [];
  final List<String> dropForeign = [];
  List<String>? compositePrimary;

  ColumnDefinition _add(ColumnDefinition c) {
    columns.add(c);
    return c;
  }

  /// Auto-incrementing big integer primary key named [name].
  ColumnDefinition id([String name = 'id']) =>
      _add(ColumnDefinition(name, 'id'));
  ColumnDefinition foreignId(String name) =>
      _add(ColumnDefinition(name, 'foreignId'));
  ColumnDefinition string(String name, [int length = 255]) =>
      _add(ColumnDefinition(name, 'string', length: length));
  ColumnDefinition text(String name) => _add(ColumnDefinition(name, 'text'));
  ColumnDefinition integer(String name) =>
      _add(ColumnDefinition(name, 'integer'));
  ColumnDefinition bigInteger(String name) =>
      _add(ColumnDefinition(name, 'bigInteger'));
  ColumnDefinition boolean(String name) =>
      _add(ColumnDefinition(name, 'boolean'));
  ColumnDefinition decimal(String name, [int precision = 12, int scale = 2]) =>
      _add(
        ColumnDefinition(name, 'decimal', precision: precision, scale: scale),
      );
  ColumnDefinition double_(String name) =>
      _add(ColumnDefinition(name, 'double'));
  ColumnDefinition date(String name) => _add(ColumnDefinition(name, 'date'));
  ColumnDefinition dateTime(String name) =>
      _add(ColumnDefinition(name, 'dateTime'));
  ColumnDefinition timestamp(String name) =>
      _add(ColumnDefinition(name, 'timestamp'));
  ColumnDefinition json(String name) => _add(ColumnDefinition(name, 'json'));
  ColumnDefinition uuid(String name) => _add(ColumnDefinition(name, 'uuid'));
  ColumnDefinition binary(String name) =>
      _add(ColumnDefinition(name, 'binary'));

  /// Nullable `created_at` and `updated_at` columns.
  void timestamps() {
    timestamp('created_at').nullable();
    timestamp('updated_at').nullable();
  }

  /// Nullable `deleted_at` column used by soft deletes.
  void softDeletes([String name = 'deleted_at']) => timestamp(name).nullable();

  void primary(List<String> cols) => compositePrimary = cols;
  void unique(List<String> cols, {String? name}) =>
      indexes.add(IndexDefinition(cols, unique: true, name: name));
  void index(List<String> cols, {String? name}) =>
      indexes.add(IndexDefinition(cols, name: name));
  ForeignKeyDefinition foreign(String column) {
    final f = ForeignKeyDefinition(column);
    foreignKeys.add(f);
    return f;
  }

  // ---- alter operations ---------------------------------------------------
  void dropColumn(String name) => dropColumns.add(name);
  void renameColumn(String from, String to) => renameColumns[from] = to;
  void dropIndex(String name) => dropIndexes.add(name);
  void dropForeignKey(String constraintName) => dropForeign.add(constraintName);
}
