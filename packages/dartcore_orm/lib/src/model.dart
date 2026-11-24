import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_validation/dartcore_validation.dart';

import 'relations.dart';

/// Value converters for hydrating rows (databases differ: SQLite returns 1/0
/// for booleans, MySQL may return ints for decimals, ...).
abstract final class Casts {
  static bool? asBool(Object? v) => v == null
      ? null
      : (v is bool
            ? v
            : (v is num
                  ? v != 0
                  : '$v' == '1' || '$v'.toLowerCase() == 'true'));
  static int? asInt(Object? v) => v == null
      ? null
      : (v is int ? v : (v is num ? v.toInt() : int.tryParse('$v')));
  static double? asDouble(Object? v) =>
      v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
  static DateTime? asDate(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    final s = '$v';
    return DateTime.tryParse(
      s.contains('Z') || s.contains('+') ? s : '${s.replaceFirst(' ', 'T')}Z',
    )?.toUtc();
  }
}

/// Base class for models.
///
/// Dart has no runtime reflection in compiled apps, so a model declares its
/// own mapping: [toMap] (fields to persist) and [fillFromMap] (hydrate from a
/// row). `dartcore make:model` generates both.
///
/// ```dart
/// class User extends Model {
///   int? id; String? name; String? email; bool active = true;
///
///   @override String get table => 'users';
///   @override List<String> get fillable => ['name', 'email'];
///   @override Map<String, Object?> toMap() =>
///       {'id': id, 'name': name, 'email': email, 'active': active};
///   @override void fillFromMap(Map<String, Object?> m) {
///     if (m.containsKey('id')) id = Casts.asInt(m['id']);
///     if (m.containsKey('name')) name = m['name'] as String?;
///     ...
///   }
///
///   static final repo = ModelRepository<User>(User.new);
///   static Future<User?> find(Object id) => repo.find(id);
///   static ModelQuery<User> query() => repo.query();
/// }
/// ```
abstract class Model {
  String get table;
  String get primaryKey => 'id';

  /// Maintain `created_at` / `updated_at` automatically.
  bool get timestamps => true;

  /// Use `deleted_at` so `delete()` hides rows instead of removing them.
  bool get softDeletes => false;

  /// Attributes `fill()` / `create()` / `update()` may set from user input.
  /// **Empty by default: nothing is mass-assignable until you list it.**
  List<String> get fillable => const [];

  /// Attributes removed from [toJson].
  List<String> get hidden => const [];

  /// Validation rules checked by [validate] and before every [save].
  Map<String, Object> get rules => const {};

  /// Named connection; `null` uses the default.
  String? get connection => null;

  /// Relations available for eager loading by name.
  Map<String, RelationDef> get relationDefs => const {};

  Map<String, Object?> toMap();
  void fillFromMap(Map<String, Object?> row);

  // ---- state --------------------------------------------------------------

  bool exists = false;
  DateTime? createdAt, updatedAt, deletedAt;
  Map<String, Object?> raw = const {};
  final Map<String, Object?> relations = {};

  bool get trashed => deletedAt != null;

  Object? get key => toMap()[primaryKey] ?? raw[primaryKey];

  DatabaseOperations get db => DB.manager.connection(connection);

  /// Sets only [fillable] attributes from [attributes]; everything else is
  /// dropped (mass-assignment protection).
  void fill(Map<String, Object?> attributes) => fillFromMap({
    for (final e in attributes.entries)
      if (fillable.contains(e.key)) e.key: e.value,
  });

  /// Sets any attribute. Use only with trusted data.
  void forceFill(Map<String, Object?> attributes) => fillFromMap(attributes);

  /// Loads a database row into this model.
  void hydrate(Map<String, Object?> row) {
    raw = Map.of(row);
    fillFromMap(row);
    createdAt = Casts.asDate(row['created_at']);
    updatedAt = Casts.asDate(row['updated_at']);
    deletedAt = Casts.asDate(row['deleted_at']);
    exists = true;
  }

  // ---- lifecycle hooks (throw to abort) ----------------------------------------

  Future<void> onSaving() async {}
  Future<void> onCreating() async {}
  Future<void> onCreated() async {}
  Future<void> onUpdating() async {}
  Future<void> onUpdated() async {}
  Future<void> onSaved() async {}
  Future<void> onDeleting() async {}
  Future<void> onDeleted() async {}

  // ---- validation ----------------------------------------------------------

  /// Validates [toMap] against [rules]; throws [ValidationException].
  void validate() {
    if (rules.isEmpty) return;
    Validate.request(toMap(), rules).orThrow();
  }

  // ---- persistence --------------------------------------------------------------

  QueryBuilder get _q => db.table(table, primaryKey: primaryKey);

  /// Inserts or updates depending on [exists].
  Future<void> save() async {
    validate();
    await onSaving();
    final now = DateTime.now().toUtc();
    final data = Map<String, Object?>.of(toMap());
    if (exists) {
      await onUpdating();
      final id = key;
      if (id == null) {
        throw DatabaseException('Cannot update a model without a primary key.');
      }
      data.remove(primaryKey);
      if (timestamps) {
        data['updated_at'] = now;
        updatedAt = now;
      }
      if (data.isNotEmpty) await _q.where(primaryKey, id).update(data);
      await onUpdated();
    } else {
      await onCreating();
      if (data[primaryKey] == null) data.remove(primaryKey);
      if (timestamps) {
        data['created_at'] = now;
        data['updated_at'] = now;
      }
      final row = await _q.insert(data);
      hydrate({...data, ...row});
      await onCreated();
    }
    await onSaved();
  }

  /// Mass-assigns [attributes] (respecting [fillable]) and saves.
  Future<void> update(Map<String, Object?> attributes) async {
    fill(attributes);
    await save();
  }

  /// Deletes the row, or soft-deletes it when [softDeletes] is on.
  Future<void> delete() async {
    _requireExists('delete');
    await onDeleting();
    if (softDeletes) {
      final now = DateTime.now().toUtc();
      await _q.where(primaryKey, key!).update({'deleted_at': now});
      deletedAt = now;
    } else {
      await _q.where(primaryKey, key!).delete();
      exists = false;
    }
    await onDeleted();
  }

  /// Permanently deletes the row even for soft-deleting models.
  Future<void> forceDelete() async {
    _requireExists('forceDelete');
    await onDeleting();
    await _q.where(primaryKey, key!).delete();
    exists = false;
    await onDeleted();
  }

  Future<void> restore() async {
    _requireExists('restore');
    await _q.where(primaryKey, key!).update({'deleted_at': null});
    deletedAt = null;
  }

  /// Reloads attributes from the database.
  Future<void> refresh() async {
    _requireExists('refresh');
    final row = await _q.where(primaryKey, key!).first();
    if (row == null) {
      exists = false;
      throw NotFoundException('${runtimeType.toString()} no longer exists.');
    }
    hydrate(row);
  }

  void _requireExists(String op) {
    if (!exists || key == null) {
      throw DatabaseException('Cannot $op a model that is not persisted.');
    }
  }

  // ---- relationships -----------------------------------------------------------

  /// Lazy relation queries. Pass the related model's constructor tear-off:
  /// `user.hasMany(Post.new)`.
  ModelQuery<T> hasOne<T extends Model>(
    T Function() related, {
    String? foreignKey,
    String? localKey,
  }) => HasOne<T>(
    related,
    foreignKey: foreignKey,
    localKey: localKey,
  ).query(this);

  ModelQuery<T> hasMany<T extends Model>(
    T Function() related, {
    String? foreignKey,
    String? localKey,
  }) => HasMany<T>(
    related,
    foreignKey: foreignKey,
    localKey: localKey,
  ).query(this);

  ModelQuery<T> belongsTo<T extends Model>(
    T Function() related, {
    String? foreignKey,
    String? ownerKey,
  }) => BelongsTo<T>(
    related,
    foreignKey: foreignKey,
    ownerKey: ownerKey,
  ).query(this);

  ModelQuery<T> belongsToMany<T extends Model>(
    T Function() related, {
    String? pivotTable,
    String? foreignPivotKey,
    String? relatedPivotKey,
  }) => BelongsToMany<T>(
    related,
    pivotTable: pivotTable,
    foreignPivotKey: foreignPivotKey,
    relatedPivotKey: relatedPivotKey,
  ).query(this);

  /// Loaded relation (many).
  List<T> many<T extends Model>(String name) =>
      (relations[name] as List?)?.cast<T>() ?? const [];

  /// Loaded relation (one).
  T? one<T extends Model>(String name) => relations[name] as T?;

  /// Serializable map: [toMap] minus [hidden], plus timestamps and loaded relations.
  Map<String, Object?> toJson() => {
    for (final e in toMap().entries)
      if (!hidden.contains(e.key)) e.key: e.value,
    if (timestamps) ...{'created_at': createdAt, 'updated_at': updatedAt},
    if (softDeletes) 'deleted_at': deletedAt,
    for (final r in relations.entries)
      r.key: r.value is List
          ? [for (final m in r.value as List) (m as Model).toJson()]
          : (r.value as Model?)?.toJson(),
  };
}

/// Entry point for querying a model type: `ModelRepository<User>(User.new)`.
class ModelRepository<T extends Model> {
  ModelRepository(this.factory);
  final T Function() factory;

  ModelQuery<T> query() => ModelQuery<T>(factory);

  Future<List<T>> all() => query().get();
  Future<T?> find(Object id) => query().find(id);

  Future<T> findOrFail(Object id) async =>
      await find(id) ??
      (throw NotFoundException('${factory().runtimeType} not found.'));

  /// Mass-assigns [attributes] (respecting `fillable`) and inserts.
  Future<T> create(Map<String, Object?> attributes) async {
    final m = factory()..fill(attributes);
    await m.save();
    return m;
  }
}

/// A model-aware query: results are hydrated models.
class ModelQuery<T extends Model> {
  ModelQuery(this._factory, {QueryBuilder? builder})
    : _sample = _factory(),
      _builder = builder {
    _builder ??= _sample.db.table(
      _sample.table,
      primaryKey: _sample.primaryKey,
    );
  }

  final T Function() _factory;
  final T _sample;
  QueryBuilder? _builder;
  final List<String> _with = [];
  bool _withTrashed = false, _onlyTrashed = false;

  QueryBuilder get builder => _builder!;

  ModelQuery<T> where(String column, Object? a, [Object? b = _unset]) {
    identical(b, _unset)
        ? builder.where(column, a)
        : builder.where(column, a, b);
    return this;
  }

  ModelQuery<T> orWhere(String column, Object? a, [Object? b = _unset]) {
    identical(b, _unset)
        ? builder.orWhere(column, a)
        : builder.orWhere(column, a, b);
    return this;
  }

  ModelQuery<T> whereIn(String column, Iterable<Object?> values) {
    builder.whereIn(column, values);
    return this;
  }

  ModelQuery<T> whereNull(String column) {
    builder.whereNull(column);
    return this;
  }

  ModelQuery<T> whereNotNull(String column) {
    builder.whereNotNull(column);
    return this;
  }

  ModelQuery<T> whereGroup(void Function(QueryBuilder q) f) {
    builder.whereGroup(f);
    return this;
  }

  ModelQuery<T> when(bool cond, void Function(ModelQuery<T> q) f) {
    if (cond) f(this);
    return this;
  }

  ModelQuery<T> orderBy(String column, {bool descending = false}) {
    builder.orderBy(column, descending: descending);
    return this;
  }

  ModelQuery<T> limit(int n) {
    builder.limit(n);
    return this;
  }

  ModelQuery<T> offset(int n) {
    builder.offset(n);
    return this;
  }

  /// Eager-load relations declared in the model's [Model.relationDefs]
  /// (one extra query per relation, not one per row).
  ModelQuery<T> withRelations(List<String> names) {
    _with.addAll(names);
    return this;
  }

  ModelQuery<T> withTrashed() {
    _withTrashed = true;
    return this;
  }

  ModelQuery<T> onlyTrashed() {
    _onlyTrashed = true;
    return this;
  }

  QueryBuilder _scoped() {
    final b = builder.clone();
    if (_sample.softDeletes && !_withTrashed) {
      _onlyTrashed ? b.whereNotNull('deleted_at') : b.whereNull('deleted_at');
    }
    return b;
  }

  T _make(Map<String, Object?> row) => _factory()..hydrate(row);

  Future<List<T>> get() async {
    final models = [for (final r in await _scoped().get()) _make(r)];
    await _eagerLoad(models);
    return models;
  }

  Future<T?> first() async {
    final rows = await (_scoped()..limit(1)).get();
    if (rows.isEmpty) return null;
    final m = _make(rows.first);
    await _eagerLoad([m]);
    return m;
  }

  Future<T?> find(Object id) =>
      (clone()..where(_sample.primaryKey, id)).first();

  Future<int> count() => _scoped().count();
  Future<bool> exists() => _scoped().exists();

  Future<ModelPage<T>> paginate({int page = 1, int limit = 20}) async {
    final p = await _scoped().paginate(page: page, limit: limit);
    final models = [for (final r in p.data) _make(r)];
    await _eagerLoad(models);
    return ModelPage<T>(models, p);
  }

  ModelQuery<T> clone() => ModelQuery<T>(_factory, builder: builder.clone())
    .._with.addAll(_with)
    .._withTrashed = _withTrashed
    .._onlyTrashed = _onlyTrashed;

  Future<void> _eagerLoad(List<T> models) async {
    if (models.isEmpty) return;
    for (final name in _with) {
      final def =
          _sample.relationDefs[name] ??
          (throw ArgumentError(
            'Unknown relation "$name" on ${_sample.runtimeType}.',
          ));
      await def.eagerLoad(name, models, _sample.db);
    }
  }
}

const Object _unset = Object();

class ModelPage<T extends Model> {
  ModelPage(this.data, this._p);
  final List<T> data;
  final Paginator _p;
  int get currentPage => _p.currentPage;
  int get perPage => _p.perPage;
  int get total => _p.total;
  int get lastPage => _p.lastPage;
  bool get hasNextPage => _p.hasNextPage;
  bool get hasPreviousPage => _p.hasPreviousPage;
  Map<String, Object?> get meta => _p.meta;
  Map<String, Object?> toJson() => {
    'data': [for (final m in data) m.toJson()],
    'meta': meta,
  };
}
