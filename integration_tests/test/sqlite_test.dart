import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

import 'contract.dart';

void main() {
  runContract(
    EngineSpec(
      name: 'SQLite',
      config: const ConnectionConfig(
        driver: DatabaseDriver.sqlite,
        database: ':memory:',
      ),
      idColumn: 'INTEGER PRIMARY KEY AUTOINCREMENT',
      boolType: 'INTEGER',
      dropIfExists: (t) => 'DROP TABLE IF EXISTS $t',
    ),
    register: () async => registerSqlite(),
  );
}
