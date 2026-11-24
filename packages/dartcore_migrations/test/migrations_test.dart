import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

class CreateUsers extends Migration {
  @override
  String get id => '2025_01_01_000001_create_users_table';
  @override
  Future<void> up(SchemaBuilder s) => Schema.create('users', (t) {
    t.id();
    t.string('name');
    t.string('email').unique();
    t.boolean('active').defaultValue(true);
    t.decimal('balance', 12, 2).defaultValue(0);
    t.timestamps();
  });
  @override
  Future<void> down(SchemaBuilder s) => Schema.dropIfExists('users');
}

class CreatePosts extends Migration {
  @override
  String get id => '2025_01_01_000002_create_posts_table';
  @override
  Future<void> up(SchemaBuilder s) => Schema.create('posts', (t) {
    t.id();
    t.foreignId('user_id').references('users').onDelete('cascade');
    t.string('title');
    t.text('body').nullable();
    t.index(['title']);
  });
  @override
  Future<void> down(SchemaBuilder s) => Schema.drop('posts');
}

class Broken extends Migration {
  @override
  String get id => '2025_01_01_000003_broken';
  @override
  Future<void> up(SchemaBuilder s) async {
    await Schema.create('half', (t) => t.id());
    await Schema.create('users', (t) => t.id()); // already exists -> fails
  }

  @override
  Future<void> down(SchemaBuilder s) async {}
}

class UserSeeder extends Seeder {
  @override
  Future<void> run() => DB.table('users').insertMany([
    {'name': 'John', 'email': 'john@example.com'},
    {'name': 'Jane', 'email': 'jane@example.com'},
  ]);
}

void main() {
  late DatabaseManager m;
  late Database db;
  setUpAll(registerSqlite);
  setUp(() async {
    m = DatabaseManager();
    DB.use(m);
    db = await m.connect(
      const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
    );
  });
  tearDown(() => m.disconnect());

  test('migrate creates tables, tracks batches and is idempotent', () async {
    final mig = Migrator(db, [
      CreatePosts(),
      CreateUsers(),
    ]); // order independent
    final ran = await mig.migrate();
    expect(ran, [
      '2025_01_01_000001_create_users_table',
      '2025_01_01_000002_create_posts_table',
    ]);
    expect(await SchemaBuilder(db).hasTable('users'), isTrue);
    expect(await SchemaBuilder(db).hasColumn('users', 'email'), isTrue);
    expect(await mig.migrate(), isEmpty, reason: 'no duplicate execution');
    final u = await db.table('users').insert({'name': 'A', 'email': 'a@x'});
    expect(u['active'], 1);
    expect(u['balance'], 0);
    await expectLater(
      db.table('users').insert({'name': 'B', 'email': 'a@x'}),
      throwsA(isA<QueryException>()),
    );
    await db.table('posts').insert({'user_id': u['id'], 'title': 't'});
    // foreign key enforced
    await expectLater(
      db.table('posts').insert({'user_id': 999, 'title': 't'}),
      throwsA(isA<QueryException>()),
    );
    // cascade
    await db.table('users').where('id', u['id']!).delete();
    expect(await db.table('posts').count(), 0);
  });

  test('rollback by batch, reset requires confirmation', () async {
    final mig = Migrator(db, [CreateUsers()]);
    await mig.migrate();
    final mig2 = Migrator(db, [CreateUsers(), CreatePosts()]);
    await mig2.migrate();
    final st = await mig2.status();
    expect(st.map((s) => s.batch), [1, 2]);
    expect(await mig2.rollback(), ['2025_01_01_000002_create_posts_table']);
    expect(await SchemaBuilder(db).hasTable('posts'), isFalse);
    expect(await SchemaBuilder(db).hasTable('users'), isTrue);
    await expectLater(
      mig2.reset(),
      throwsA(isA<UnconfirmedDestructiveActionException>()),
    );
    expect(await SchemaBuilder(db).hasTable('users'), isTrue);
    await mig2.reset(confirm: true);
    expect(await SchemaBuilder(db).hasTable('users'), isFalse);
  });

  test(
    'failed migration is rolled back atomically (transactional DDL)',
    () async {
      final mig = Migrator(db, [CreateUsers(), Broken()]);
      await expectLater(
        mig.migrate(),
        throwsA(
          isA<DatabaseException>()
              .having((e) => e.details, 'details', contains('already exists'))
              .having((e) => e.hint, 'hint', isNotNull),
        ),
      );
      expect(await SchemaBuilder(db).hasTable('half'), isFalse);
      expect((await mig.status()).where((s) => s.ran).map((s) => s.id), [
        CreateUsers().id,
      ], reason: 'the first migration committed before the broken one failed');
      expect(await SchemaBuilder(db).hasTable('users'), isTrue);
    },
  );

  test(
    'fresh drops everything incl. FK-linked tables, requires confirmation',
    () async {
      final mig = Migrator(db, [CreateUsers(), CreatePosts()]);
      await mig.migrate();
      await db.table('users').insert({'name': 'A', 'email': 'a@x'});
      await expectLater(
        mig.fresh(),
        throwsA(isA<UnconfirmedDestructiveActionException>()),
      );
      expect(await db.table('users').count(), 1);
      await mig.fresh(confirm: true);
      expect(await db.table('users').count(), 0);
    },
  );

  test('seeders run with the DB facade', () async {
    final mig = Migrator(db, [CreateUsers()]);
    await mig.migrate();
    await mig.seed([UserSeeder()]);
    expect(await db.table('users').count(), 2);
    await expectLater(
      mig.seed([UserSeeder()], only: 'Nope'),
      throwsA(isA<ConfigurationException>()),
    );
  });

  test(
    'alter table: add/rename/drop column, index; honest SQLite limits',
    () async {
      await db.statement('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
      final s = SchemaBuilder(db);
      await s.table('t', (b) {
        b.string('b').nullable();
        b.renameColumn('a', 'a2');
        b.index(['b']);
      });
      expect(await s.hasColumn('t', 'b'), isTrue);
      expect(await s.hasColumn('t', 'a2'), isTrue);
      await s.table('t', (b) {
        b.dropIndex('t_b_index'); // SQLite refuses to drop an indexed column
        b.dropColumn('b');
      });
      expect(await s.hasColumn('t', 'b'), isFalse);
      await s.rename('t', 't2');
      expect(await s.hasTable('t2'), isTrue);
      expect(
        () => s.table('t2', (b) => b.string('x').change()),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => s.table('t2', (b) => b.string('u').unique()),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  group('DDL compilation per dialect', () {
    String create(SqlDialect d, void Function(Blueprint) f) {
      final bp = Blueprint('users');
      f(bp);
      final exec = _Null();
      return SchemaBuilder(_Ops(d, exec)).compileCreate(bp).join(';\n');
    }

    void users(Blueprint t) {
      t.id();
      t.string('email', 100).unique();
      t.boolean('active').defaultValue(true);
      t.json('meta').nullable();
      t.timestamps();
      t.foreignId('org_id').references('orgs').onDelete('cascade');
    }

    test('postgres', () {
      final sql = create(const PostgresDialect(), users);
      expect(sql, contains('"id" BIGSERIAL PRIMARY KEY'));
      expect(sql, contains('"active" BOOLEAN NOT NULL DEFAULT TRUE'));
      expect(sql, contains('"meta" JSONB NULL'));
      expect(sql, contains('"org_id" BIGINT NOT NULL'));
      expect(
        sql,
        contains(
          'FOREIGN KEY ("org_id") REFERENCES "orgs" ("id") ON DELETE CASCADE',
        ),
      );
    });
    test('mysql', () {
      final sql = create(const MySqlDialect(), users);
      expect(sql, contains('`id` BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY'));
      expect(sql, contains('`active` TINYINT(1) NOT NULL DEFAULT 1'));
      expect(sql, contains('`org_id` BIGINT UNSIGNED NOT NULL'));
    });
    test('sqlite', () {
      expect(
        create(const SqliteDialect(), users),
        contains('"id" INTEGER PRIMARY KEY AUTOINCREMENT'),
      );
    });
    test('mssql', () {
      final sql = create(const MssqlDialect(), users);
      expect(sql, contains('[id] BIGINT IDENTITY(1,1) PRIMARY KEY'));
      expect(sql, contains('[active] BIT NOT NULL DEFAULT 1'));
      expect(sql, contains('[email] NVARCHAR(100) NOT NULL UNIQUE'));
    });
    test('hostile identifiers and fk actions are rejected', () {
      expect(
        () => create(
          const PostgresDialect(),
          (t) => t.string('a"; DROP TABLE x; --'),
        ),
        throwsA(isA<QueryException>()),
      );
      expect(
        () => create(
          const PostgresDialect(),
          (t) => t.foreignId('a').references('b').onDelete('cascade; DROP'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('console', () {
    test('migrate / status / rollback / destructive confirmation', () async {
      final out = StringBuffer();
      var answer = false;
      final c = MigrationConsole(
        database: db,
        migrations: [CreateUsers()],
        seeders: [UserSeeder()],
        out: out,
        confirm: (_) => answer,
      );
      expect(await c.run(['migrate']), 0);
      expect(
        out.toString(),
        contains('Migrated:  2025_01_01_000001_create_users_table'),
      );
      expect(await c.run(['migrate:status']), 0);
      expect(out.toString(), contains('[x] batch 1'));
      expect(await c.run(['migrate:fresh']), 1, reason: 'declined');
      expect(await SchemaBuilder(db).hasTable('users'), isTrue);
      answer = true;
      expect(await c.run(['migrate:fresh', '--seed']), 0);
      expect(await db.table('users').count(), 2);
      expect(await c.run(['bogus']), 64);
    });

    test('doctor reports connection and pending migrations', () async {
      final out = StringBuffer();
      var code = await MigrationConsole.doctor(
        connect: () async {},
        database: () => db,
        migrations: [CreateUsers()],
        out: out,
      );
      expect(code, 0);
      expect(out.toString(), contains('OK    Database connection: SELECT 1'));
      expect(
        out.toString(),
        contains('WARN  Migrations: 0 applied, 1 pending'),
      );
      expect(
        await SchemaBuilder(db).hasTable('dartcore_migrations'),
        isFalse,
        reason: 'doctor must not create the migrations table',
      );
      await Migrator(db, [CreateUsers()]).migrate();
      out.clear();
      await MigrationConsole.doctor(
        connect: () async {},
        database: () => db,
        migrations: [CreateUsers()],
        out: out,
      );
      expect(out.toString(), contains('OK    Migrations: 1 applied, none'));
    });

    test('doctor fails clearly when it cannot connect', () async {
      final out = StringBuffer();
      final code = await MigrationConsole.doctor(
        connect: () async => throw ConnectionException('refused'),
        database: () => db,
        migrations: const [],
        out: out,
      );
      expect(code, 1);
      expect(out.toString(), contains('FAIL  Database connection'));
      expect(out.toString(), contains('refused'));
      expect(out.toString(), contains('Fix:'));
    });

    test('production refuses destructive commands without --force', () async {
      final out = StringBuffer();
      final c = MigrationConsole(
        database: db,
        migrations: [CreateUsers()],
        environment: AppEnvironment.production,
        out: out,
        confirm: (_) => true,
      );
      await c.run(['migrate']);
      expect(await c.run(['migrate:fresh']), 1);
      expect(out.toString(), contains('without --force'));
      expect(await SchemaBuilder(db).hasTable('users'), isTrue);
      expect(await c.run(['migrate:rollback', '--force']), 0);
      expect(await SchemaBuilder(db).hasTable('users'), isFalse);
    });
  });
}

class _Null implements DatabaseExecutor {
  @override
  Future<QueryResult> execute(CompiledQuery query) async => const QueryResult();
}

class _Ops with DatabaseOperations {
  _Ops(this.dialect, this.executor);
  @override
  final SqlDialect dialect;
  @override
  final DatabaseExecutor executor;
}
