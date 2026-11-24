import 'package:dartcore_migrations/dartcore_migrations.dart';

class CreateUsersTable extends Migration {
  @override
  String get id => '2025_01_01_000001_create_users_table';
  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('users', (t) {
    t.id();
    t.string('name');
    t.string('email').unique();
    t.string('password');
    t.string('role', 20).defaultValue('user');
    t.timestamps();
  });
  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('users');
}

class CreateProductsTable extends Migration {
  @override
  String get id => '2025_01_01_000002_create_products_table';
  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('products', (t) {
    t.id();
    t.string('name');
    t.text('description').nullable();
    t.decimal('price', 12, 2);
    t.integer('stock').defaultValue(0);
    t.boolean('active').defaultValue(true);
    t.timestamps();
  });
  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('products');
}

final migrations = <Migration>[CreateUsersTable(), CreateProductsTable()];
