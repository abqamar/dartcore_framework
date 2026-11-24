import 'package:complete_application/app.dart';
import 'package:complete_application/migrations.dart';
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

/// PostgreSQL (default, see integration_tests/docker-compose.yml):
///   docker compose -f ../../integration_tests/docker-compose.yml up -d postgres
///   dart run bin/server.dart
/// SQLite instead:
///   DB_DRIVER=sqlite DB_DATABASE=app.sqlite dart run bin/server.dart
Future<void> main() async {
  await Config.load();
  registerPostgres();
  registerSqlite();

  final driver = Config.get('DB_DRIVER', 'postgres')!;
  final database = DB.manager;
  final conn = await database.connect(
    driver == 'sqlite'
        ? ConnectionConfig(
            driver: DatabaseDriver.sqlite,
            database: Config.get('DB_DATABASE', 'app.sqlite')!,
          )
        : ConnectionConfig(
            driver: DatabaseDriver.postgres,
            host: Config.get('DB_HOST', 'localhost')!,
            port: Config.getInt('DB_PORT', 5432),
            database: Config.get('DB_DATABASE', 'dartcore_test')!,
            username: Config.get('DB_USERNAME', 'dartcore'),
            password: Config.get('DB_PASSWORD', 'dartcore'),
          ),
  );

  await Migrator(conn, migrations).migrate(onProgress: Log.info);
  await DatabaseAuthStores.createTables(conn);

  final app = buildApp(
    database,
    jwtSecret: Config.require('JWT_SECRET'),
  ); // openssl rand -base64 48
  await app.start();
}
