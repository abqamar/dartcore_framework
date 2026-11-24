import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:test/test.dart';

class _CreateUsers extends Migration {
  @override
  String get id => '2025_01_01_000001_create_users';
  @override
  Future<void> up(SchemaBuilder s) => Schema.create('mg_users', (t) {
    t.id();
    t.string('name');
    t.string('email', 120).unique();
    t.boolean('active').defaultValue(true);
    t.decimal('balance', 12, 2).defaultValue(0);
    t.json('meta').nullable();
    t.timestamps();
  });
  @override
  Future<void> down(SchemaBuilder s) => Schema.dropIfExists('mg_users');
}

class _CreatePosts extends Migration {
  @override
  String get id => '2025_01_01_000002_create_posts';
  @override
  Future<void> up(SchemaBuilder s) => Schema.create('mg_posts', (t) {
    t.id();
    t.foreignId('user_id').references('mg_users').onDelete('cascade');
    t.string('title');
    t.text('body').nullable();
    t.index(['title']);
  });
  @override
  Future<void> down(SchemaBuilder s) => Schema.dropIfExists('mg_posts');
}

/// Runs the same migrations on a real engine: create, FK enforcement,
/// cascade, rollback, alter, fresh.
void runMigrationContract(
  String name,
  ConnectionConfig config,
  Future<void> Function() register,
) {
  group('$name migrations', () {
    late DatabaseManager m;
    Database? db;
    String? skip;

    setUpAll(() async {
      await register();
      m = DatabaseManager();
      try {
        db = await m.connect(config);
        await Migrator(db!, [
          _CreateUsers(),
          _CreatePosts(),
        ]).fresh(confirm: true); // clean slate
        await Migrator(db!, [
          _CreateUsers(),
          _CreatePosts(),
        ]).reset(confirm: true);
      } on Exception catch (e) {
        skip = '$name not reachable: $e';
      }
    });
    tearDownAll(() => m.disconnect());

    test('migrate, constraints, cascade, rollback, alter', () async {
      if (db == null) return markTestSkipped(skip!);
      final mig = Migrator(db!, [_CreateUsers(), _CreatePosts()]);
      expect(await mig.migrate(), hasLength(2));
      expect(await mig.migrate(), isEmpty);
      final s = SchemaBuilder(db!);
      expect(await s.hasTable('mg_users'), isTrue);
      expect(await s.hasColumn('mg_users', 'email'), isTrue);

      final u = await db!.table('mg_users').insert({
        'name': 'A',
        'email': 'a@x',
        'meta': {'k': 1},
      });
      await db!.table('mg_posts').insert({'user_id': u['id'], 'title': 't'});
      await expectLater(
        db!.table('mg_users').insert({'name': 'B', 'email': 'a@x'}),
        throwsA(isA<Exception>()),
        reason: 'unique enforced',
      );
      await expectLater(
        db!.table('mg_posts').insert({'user_id': 99999, 'title': 'x'}),
        throwsA(isA<Exception>()),
        reason: 'foreign key enforced',
      );
      await db!.table('mg_users').where('id', u['id']!).delete();
      expect(await db!.table('mg_posts').count(), 0, reason: 'cascade');

      await s.table('mg_users', (t) => t.string('nick', 50).nullable());
      expect(await s.hasColumn('mg_users', 'nick'), isTrue);
      if (db!.dialect is! SqliteDialect) {
        await s.table(
          'mg_users',
          (t) => t.string('nick', 80).nullable().change(),
        );
      }

      expect(await mig.rollback(), hasLength(2));
      expect(await s.hasTable('mg_users'), isFalse);
      expect(await s.hasTable('dartcore_migrations'), isTrue);
    });

    test('fresh drops all tables and re-migrates', () async {
      if (db == null) return markTestSkipped(skip!);
      final mig = Migrator(db!, [_CreateUsers(), _CreatePosts()]);
      await mig.migrate();
      await db!.table('mg_users').insert({'name': 'A', 'email': 'f@x'});
      expect(await mig.fresh(confirm: true), hasLength(2));
      expect(await db!.table('mg_users').count(), 0);
      await mig.reset(confirm: true);
    });
  });
}
