// ignore_for_file: file_names
import 'package:dartcore_migrations/dartcore_migrations.dart';

class CreateUsersTable extends Migration {
  @override
  String get id => '2026_11_24_131931_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.string('password');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('users');
}
