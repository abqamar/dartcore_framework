import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';

import 'contract.dart';

void main() {
  runContract(
    EngineSpec(
      name: 'PostgreSQL',
      config: const ConnectionConfig(
        driver: DatabaseDriver.postgres,
        host: 'localhost',
        port: 54329,
        database: 'dartcore_test',
        username: 'dartcore',
        password: 'dartcore',
        maxPoolSize: 5,
      ),
      idColumn: 'SERIAL PRIMARY KEY',
      boolType: 'BOOLEAN',
      boolTrue: 'TRUE',
      dropIfExists: (t) => 'DROP TABLE IF EXISTS $t CASCADE',
    ),
    register: () async => registerPostgres(),
  );
}
