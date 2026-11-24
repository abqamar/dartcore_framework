import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';

import 'schema.dart';

/// A schema change. [id] must be unique and sortable, conventionally
/// `2025_01_31_120000_create_users_table`.
abstract class Migration {
  const Migration();

  String get id;
  Future<void> up(SchemaBuilder schema);
  Future<void> down(SchemaBuilder schema);
}

/// Seeds data. `DB` (the default connection) is available as usual; [db] is
/// the connection the runner is using, which is safer when several exist.
abstract class Seeder {
  late DatabaseOperations db;
  Future<void> run();

  /// Runs another seeder with the same connection.
  Future<void> call(Seeder other) {
    other.db = db;
    return other.run();
  }
}

class MigrationStatus {
  const MigrationStatus(this.id, this.ran, this.batch);
  final String id;
  final bool ran;
  final int? batch;
}

/// Runs migrations against one [Database], tracking them in
/// `dartcore_migrations`.
///
/// Notes: PostgreSQL, SQLite and SQL Server run each migration in a
/// transaction. MySQL commits DDL implicitly, so a failing migration can be
/// partially applied there; keep MySQL migrations small. Concurrent migrators
/// are not locked: run migrations from one place (a deploy step).
class Migrator {
  Migrator(this.db, this.migrations, {this.tableName = 'dartcore_migrations'}) {
    final seen = <String>{};
    for (final m in migrations) {
      if (!seen.add(m.id)) {
        throw ArgumentError('Duplicate migration id "${m.id}".');
      }
    }
  }

  final Database db;
  final List<Migration> migrations;
  final String tableName;

  List<Migration> get _sorted =>
      [...migrations]..sort((a, b) => a.id.compareTo(b.id));
  SchemaBuilder get _schema => SchemaBuilder(db);
  bool get _transactionalDdl => db.dialect is! MySqlDialect;

  Future<void> _ensureTable() async {
    final schema = _schema;
    if (await schema.hasTable(tableName)) return;
    await schema.create(tableName, (t) {
      t.id();
      t.string('migration').unique();
      t.integer('batch');
      t.timestamp('executed_at').useCurrent();
    });
  }

  Future<Map<String, int>> _ran() async {
    await _ensureTable();
    final rows = await db.table(tableName).orderBy('id').get();
    return {
      for (final r in rows)
        r['migration'] as String: (r['batch'] as num).toInt(),
    };
  }

  Future<List<MigrationStatus>> status() async {
    final ran = await _ran();
    return [
      for (final m in _sorted)
        MigrationStatus(m.id, ran.containsKey(m.id), ran[m.id]),
    ];
  }

  /// Runs all pending migrations as one batch. Returns the ids that ran.
  Future<List<String>> migrate({
    void Function(String message)? onProgress,
  }) async {
    final ran = await _ran();
    final pending = _sorted.where((m) => !ran.containsKey(m.id)).toList();
    if (pending.isEmpty) return const [];
    final batch = (ran.values.fold<int>(0, (a, b) => a > b ? a : b)) + 1;
    final done = <String>[];
    for (final m in pending) {
      onProgress?.call('Migrating: ${m.id}');
      await _runIn((schema, ops) async {
        await Schema.runWith(schema, () => m.up(schema));
        await ops.table(tableName).insert({'migration': m.id, 'batch': batch});
      }, 'migration "${m.id}"');
      done.add(m.id);
      onProgress?.call('Migrated:  ${m.id}');
    }
    return done;
  }

  /// Rolls back the last [steps] batches. Returns the ids rolled back.
  Future<List<String>> rollback({
    int steps = 1,
    void Function(String message)? onProgress,
  }) async {
    final ran = await _ran();
    if (ran.isEmpty) return const [];
    final maxBatch = ran.values.reduce((a, b) => a > b ? a : b);
    final minBatch = maxBatch - steps + 1;
    final byId = {for (final m in migrations) m.id: m};
    final toRollback =
        ran.entries.where((e) => e.value >= minBatch).map((e) => e.key).toList()
          ..sort((a, b) => b.compareTo(a));
    final done = <String>[];
    for (final id in toRollback) {
      final m =
          byId[id] ??
          (throw ConfigurationException(
            'Migration "$id" is recorded as run but its class is missing; cannot roll back.',
          ));
      onProgress?.call('Rolling back: $id');
      await _runIn((schema, ops) async {
        await Schema.runWith(schema, () => m.down(schema));
        await ops.table(tableName).where('migration', id).delete();
      }, 'rollback of "$id"');
      done.add(id);
    }
    return done;
  }

  /// Rolls back every migration. Destructive: requires [confirm].
  Future<List<String>> reset({bool confirm = false}) async {
    if (!confirm) {
      throw UnconfirmedDestructiveActionException('reset all migrations');
    }
    final ran = await _ran();
    if (ran.isEmpty) return const [];
    final max = ran.values.reduce((a, b) => a > b ? a : b);
    return rollback(steps: max);
  }

  /// Drops **every table** in the database and re-runs all migrations.
  /// Destructive: requires [confirm].
  Future<List<String>> fresh({bool confirm = false}) async {
    if (!confirm) {
      throw UnconfirmedDestructiveActionException('drop all tables');
    }
    final schema = _schema;
    var remaining = await schema.tables();
    // Dependency order is unknown; retry until everything is gone or no progress.
    while (remaining.isNotEmpty) {
      final before = remaining.length;
      for (final t in remaining) {
        try {
          await schema.drop(t);
        } on QueryException {
          // still referenced by a foreign key; retry next pass
        }
      }
      remaining = await schema.tables();
      if (remaining.length == before) {
        throw DatabaseException(
          'Could not drop tables (circular foreign keys?): ${remaining.join(', ')}',
        );
      }
    }
    return migrate();
  }

  Future<void> _runIn(
    Future<void> Function(SchemaBuilder schema, DatabaseOperations ops) body,
    String what,
  ) async {
    try {
      if (_transactionalDdl) {
        await db.transaction((tx) => body(SchemaBuilder(tx), tx));
      } else {
        await body(SchemaBuilder(db), db);
      }
    } on DartCoreException catch (e) {
      throw DatabaseException(
        'Failed during $what: ${e.message}',
        cause: e,
        details: e.details,
        hint: e.hint,
      );
    }
  }

  /// Runs [seeders] (or one by [only] class name) against this connection.
  Future<void> seed(List<Seeder> seeders, {String? only}) async {
    final selected = only == null
        ? seeders
        : seeders.where((s) => s.runtimeType.toString() == only).toList();
    if (only != null && selected.isEmpty) {
      throw ConfigurationException('No seeder named "$only".');
    }
    for (final s in selected) {
      s.db = db;
      await s.run();
    }
  }
}
