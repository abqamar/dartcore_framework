import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

/// Registers the database adapters and connects using the `DB_*` keys from `.env`.
///
/// This example registers both PostgreSQL (the default) and SQLite (handy for
/// tests and for trying the app without a server); `DB_DRIVER` picks one. A real
/// project only registers the adapter it uses (`registerPostgres()`).
Future<void> connectDatabase() async {
  registerPostgres();
  registerSqlite();
  await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));
}
