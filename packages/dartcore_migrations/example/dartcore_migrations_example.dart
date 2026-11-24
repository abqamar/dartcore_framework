// Migrations, schema builder and a seeder on SQLite :memory: (ran for real).
//
// Observed output of `dart run example/dartcore_migrations_example.dart`:
//
//   ran: [2025_01_01_000001_create_users_table, 2025_01_01_000002_create_posts_table]
//   ran again: []
//   status: 2025_01_01_000001_create_users_table ran=true batch=1
//   status: 2025_01_01_000002_create_posts_table ran=true batch=1
//   users seeded: 2
//   rolled back: [2025_01_01_000002_create_posts_table, 2025_01_01_000001_create_users_table]
//   has posts table: false
//   fresh() without confirm -> UnconfirmedDestructiveActionException

import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

class CreateUsersTable extends Migration {
  @override
  String get id => '2025_01_01_000001_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.boolean('active').defaultValue(true);
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('users');
}

class CreatePostsTable extends Migration {
  @override
  String get id => '2025_01_01_000002_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('posts', (table) {
    table.id();
    table.foreignId('user_id').references('users').onDelete('cascade');
    table.string('title');
    table.index(['title']);
  });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('posts');
}

class UserSeeder extends Seeder {
  @override
  Future<void> run() => DB.table('users').insertMany([
    {'name': 'John', 'email': 'john@example.com'},
    {'name': 'Jane', 'email': 'jane@example.com'},
  ]);
}

Future<void> main() async {
  registerSqlite();
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');

  final migrator = Migrator(DB.connection(), [
    CreatePostsTable(), // order does not matter: migrations run sorted by id
    CreateUsersTable(),
  ]);

  print('ran: ${await migrator.migrate()}');
  print('ran again: ${await migrator.migrate()}');

  for (final s in await migrator.status()) {
    print('status: ${s.id} ran=${s.ran} batch=${s.batch}');
  }

  // Seeders run on the default connection (see the dartcore_cli `db:seed`
  // command for the console runner).
  await UserSeeder().run();
  print('users seeded: ${await DB.table('users').count()}');

  print('rolled back: ${await migrator.rollback()}');
  print(
    'has posts table: ${await SchemaBuilder(DB.connection()).hasTable('posts')}',
  );

  try {
    await migrator.fresh(); // destructive actions must be confirmed
  } on UnconfirmedDestructiveActionException {
    print('fresh() without confirm -> UnconfirmedDestructiveActionException');
  }

  await DB.reset();
}
