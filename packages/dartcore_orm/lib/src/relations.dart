import 'package:dartcore_db/dartcore_db.dart';

import 'model.dart';

String _singular(String table) => table.endsWith('ies')
    ? '${table.substring(0, table.length - 3)}y'
    : (table.endsWith('s') ? table.substring(0, table.length - 1) : table);

/// A relationship definition. Used both for lazy queries (`user.hasMany(...)`)
/// and for eager loading by name (`withRelations(['posts'])`).
abstract class RelationDef {
  /// Loads this relation for all [parents] in a constant number of queries and
  /// stores results in `parent.relations[name]`.
  Future<void> eagerLoad(
    String name,
    List<Model> parents,
    DatabaseOperations db,
  );
}

class HasMany<T extends Model> implements RelationDef {
  HasMany(this.related, {this.foreignKey, this.localKey});
  final T Function() related;
  final String? foreignKey, localKey;

  String _fk(Model parent) => foreignKey ?? '${_singular(parent.table)}_id';
  String _lk(Model parent) => localKey ?? parent.primaryKey;

  ModelQuery<T> query(Model parent) => ModelQuery<T>(
    related,
  )..where(_fk(parent), parent.raw[_lk(parent)] ?? parent.toMap()[_lk(parent)]);

  @override
  Future<void> eagerLoad(
    String name,
    List<Model> parents,
    DatabaseOperations db,
  ) async {
    final fk = _fk(parents.first), lk = _lk(parents.first);
    Object? val(Model m) => m.raw[lk] ?? m.toMap()[lk];
    final ids = {for (final p in parents) val(p)}..remove(null);
    final rows = ids.isEmpty
        ? <T>[]
        : await ModelQuery<T>(related).whereIn(fk, ids).get();
    final grouped = <Object?, List<T>>{};
    for (final r in rows) {
      (grouped[r.raw[fk]] ??= []).add(r);
    }
    for (final p in parents) {
      p.relations[name] = grouped[val(p)] ?? <T>[];
    }
  }
}

class HasOne<T extends Model> extends HasMany<T> {
  HasOne(super.related, {super.foreignKey, super.localKey});

  @override
  Future<void> eagerLoad(
    String name,
    List<Model> parents,
    DatabaseOperations db,
  ) async {
    await super.eagerLoad(name, parents, db);
    for (final p in parents) {
      final list = p.relations[name] as List;
      p.relations[name] = list.isEmpty ? null : list.first;
    }
  }
}

class BelongsTo<T extends Model> implements RelationDef {
  BelongsTo(this.related, {this.foreignKey, this.ownerKey});
  final T Function() related;
  final String? foreignKey, ownerKey;

  String _fk() => foreignKey ?? '${_singular(related().table)}_id';
  String _ok() => ownerKey ?? related().primaryKey;

  ModelQuery<T> query(Model child) =>
      ModelQuery<T>(related)
        ..where(_ok(), child.raw[_fk()] ?? child.toMap()[_fk()]);

  @override
  Future<void> eagerLoad(
    String name,
    List<Model> parents,
    DatabaseOperations db,
  ) async {
    final fk = _fk(), ok = _ok();
    Object? val(Model m) => m.raw[fk] ?? m.toMap()[fk];
    final ids = {for (final p in parents) val(p)}..remove(null);
    final rows = ids.isEmpty
        ? <T>[]
        : await ModelQuery<T>(related).whereIn(ok, ids).get();
    final byKey = {for (final r in rows) r.raw[ok]: r};
    for (final p in parents) {
      p.relations[name] = byKey[val(p)];
    }
  }
}

class BelongsToMany<T extends Model> implements RelationDef {
  BelongsToMany(
    this.related, {
    this.pivotTable,
    this.foreignPivotKey,
    this.relatedPivotKey,
  });
  final T Function() related;
  final String? pivotTable, foreignPivotKey, relatedPivotKey;

  String _pivot(Model parent) {
    if (pivotTable != null) return pivotTable!;
    final names = [_singular(parent.table), _singular(related().table)]..sort();
    return names.join('_');
  }

  String _fpk(Model parent) =>
      foreignPivotKey ?? '${_singular(parent.table)}_id';
  String _rpk() => relatedPivotKey ?? '${_singular(related().table)}_id';

  ModelQuery<T> query(Model parent) {
    final rel = related();
    final d = parent.db.dialect;
    final pivot = Identifier.quote(d, _pivot(parent));
    final sub =
        'SELECT ${Identifier.quote(d, _rpk())} FROM $pivot WHERE ${Identifier.quote(d, _fpk(parent))} = ?';
    return ModelQuery<T>(related)
      ..builder.whereRaw('${Identifier.quote(d, rel.primaryKey)} IN ($sub)', [
        parent.raw[parent.primaryKey] ?? parent.toMap()[parent.primaryKey],
      ]);
  }

  @override
  Future<void> eagerLoad(
    String name,
    List<Model> parents,
    DatabaseOperations db,
  ) async {
    final first = parents.first;
    final fpk = _fpk(first), rpk = _rpk(), pk = first.primaryKey;
    Object? val(Model m) => m.raw[pk] ?? m.toMap()[pk];
    final ids = {for (final p in parents) val(p)}..remove(null);
    final pivots = ids.isEmpty
        ? <Map<String, Object?>>[]
        : await db.table(_pivot(first)).whereIn(fpk, ids).get();
    final relatedIds = {for (final r in pivots) r[rpk]};
    final rel = related();
    final rows = relatedIds.isEmpty
        ? <T>[]
        : await ModelQuery<T>(
            related,
          ).whereIn(rel.primaryKey, relatedIds).get();
    final byId = {for (final r in rows) r.raw[rel.primaryKey]: r};
    for (final p in parents) {
      p.relations[name] = [
        for (final pr in pivots)
          if (pr[fpk] == val(p) && byId[pr[rpk]] != null) byId[pr[rpk]]!,
      ];
    }
  }
}
