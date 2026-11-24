// ignore_for_file: file_names
import 'package:dartcore_migrations/dartcore_migrations.dart';

class CreateTasksTable extends Migration {
  @override
  String get id => '2026_11_24_131948_create_tasks_table';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('tasks', (table) {
    table.id();
    table.foreignId('user_id').references('users').onDelete('cascade');
    table.string('title');
    table.text('description').nullable();
    table.string('status', 20).defaultValue('todo');
    table.timestamp('due_at').nullable();
    table.timestamps();
    table.index(['user_id', 'status']);
  });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('tasks');
}
