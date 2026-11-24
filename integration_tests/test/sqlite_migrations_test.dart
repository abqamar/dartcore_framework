import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

import 'migrations_contract.dart';

void main() => runMigrationContract(
  'SQLite',
  const ConnectionConfig(driver: DatabaseDriver.sqlite, database: ':memory:'),
  () async => registerSqlite(),
);
