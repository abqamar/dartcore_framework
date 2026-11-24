import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'user_seeder.dart';

// dartcore:imports

/// Seeders run by `dartcore db:seed`, in order.
final List<Seeder> seeders = <Seeder>[
  UserSeeder(),
  // dartcore:entries
];
