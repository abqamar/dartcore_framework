import 'package:dartcore_migrations/dartcore_migrations.dart';
import '2026_11_24_131931_create_users_table.dart';
import '2026_11_24_131948_create_tasks_table.dart';

// dartcore:imports

/// All migrations, in any order (they run sorted by id). `dartcore make:migration`
/// appends here automatically.
final List<Migration> migrations = <Migration>[
  CreateUsersTable(),
  CreateTasksTable(),
  // dartcore:entries
];
