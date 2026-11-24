import 'dart:io';

import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:tasks_api/config/database.dart';
import 'package:tasks_api/routes/api.dart';

import '../database/migrations/index.dart';
import '../database/seeders/index.dart';

/// Entry point used by the `dartcore` CLI (migrate, db:seed, route:list, ...).
Future<void> main(List<String> args) async {
  await Config.load();

  if (args.isNotEmpty && args.first == 'route:list') {
    final app = DartCore(database: DatabaseManager());
    registerRoutes(app);
    for (final r in app.routes) {
      stdout.writeln(
        '${r.method.padRight(7)} ${r.path}${r.name != null ? '  (${r.name})' : ''}',
      );
    }
    return;
  }

  if (args.isNotEmpty && args.first == 'doctor') {
    // Used by `dartcore doctor`: checks the database with this project's adapter.
    exitCode = await MigrationConsole.doctor(
      connect: connectDatabase,
      database: DB.connection,
      migrations: migrations,
    );
    try {
      await DB.disconnect();
    } catch (_) {}
    return;
  }

  await connectDatabase();
  final console = MigrationConsole(
    database: DB.connection(),
    migrations: migrations,
    seeders: seeders,
    environment: Config.environment,
  );
  exitCode = await console.run(args);
  await DB.disconnect();
}
