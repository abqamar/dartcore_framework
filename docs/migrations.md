# Migrations, schema and seeders (`dartcore_migrations`)

```bash
dartcore make:migration create_users_table
dartcore migrate                      # run pending (one batch)
dartcore migrate:status
dartcore migrate:rollback [--step=2]  # last N batches
dartcore migrate:reset                # roll back everything   (destructive)
dartcore migrate:fresh [--seed]       # DROP ALL TABLES + migrate (destructive)
dartcore db:seed [--class=UserSeeder]
```

Destructive commands ask for confirmation; in production they refuse unless you pass `--force`. Progress is stored in
the `dartcore_migrations` table.

```dart
class CreateUsersTable extends Migration {
  @override String get id => '2025_01_31_120000_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('users', (table) {
        table.id();
        table.string('name');
        table.string('email').unique();
        table.boolean('active').defaultValue(true);
        table.foreignId('company_id').nullable().references('companies').onDelete('set null');
        table.timestamps();                    // nullable created_at / updated_at
        table.softDeletes();                   // nullable deleted_at
        table.index(['name']);
      });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('users');
}
```

Register it in `database/migrations/index.dart` (the generator does this). Migrations run sorted by `id`.

## Column types and modifiers

`id` `foreignId` `string(name, [255])` `text` `integer` `bigInteger` `boolean` `decimal(name, p, s)` `double_` `date`
`dateTime` `timestamp` `json` `uuid` `binary` · modifiers `.nullable()` `.unique()` `.index()` `.defaultValue(v)`
`.useCurrent()` `.references(table, [col])` `.onDelete(...)` `.onUpdate(...)` `.change()` · table-level `primary([...])`
`unique([...])` `index([...])` `foreign(col).references(...)`.

Alter: `Schema.table('users', (t) { t.string('nick').nullable(); t.renameColumn('a', 'b'); t.dropColumn('c');
t.dropIndex('name'); })`, `Schema.rename`, `Schema.drop`, `Schema.dropIfExists`, `Schema.hasTable`, `Schema.hasColumn`.

## Engine limits (they throw, they are not emulated)

* SQLite: `.change()` and adding a UNIQUE or foreign-key column to an existing table throw `UnsupportedError`; a column with
  an index cannot be dropped (drop the index in the same `Schema.table` call: indexes are dropped first).
* MySQL: DDL commits implicitly, so a failing migration may be partly applied. PostgreSQL, SQLite and SQL Server run each
  migration in a transaction (SQL Server schema compiles but has no adapter yet).

## Seeders

```dart
class UserSeeder extends Seeder {
  @override
  Future<void> run() async {
    await db.table('users').insertMany([
      {'name': 'John', 'email': 'john@example.com'},
      {'name': 'Jane', 'email': 'jane@example.com'},
    ]);
    await call(OtherSeeder());               // run another seeder on the same connection
  }
}
```

`DB.table(...)` also works (the default connection); `db` is the connection the runner uses. `db` is only set while a runner (the console or `Migrator`) is executing the seeder: if you call `UserSeeder().run()` yourself, use `DB.table(...)` instead (reading `db` throws `LateInitializationError`). Seeding in production needs `--force`.

## From code

```dart
final migrator = Migrator(DB.connection(), migrations);
await migrator.migrate();  await migrator.rollback();  await migrator.status();
await migrator.fresh(confirm: true);                    // throws UnconfirmedDestructiveActionException without confirm
```

There is no migration lock: run migrations from one place (a deploy step), not from every app instance.
