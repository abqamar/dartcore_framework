import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_postgres/dartcore_postgres.dart';

import 'migrations_contract.dart';

void main() => runMigrationContract(
  'Postgres',
  const ConnectionConfig(
    driver: DatabaseDriver.postgres,
    host: 'localhost',
    port: 54329,
    database: 'dartcore_test',
    username: 'dartcore',
    password: 'dartcore',
  ),
  () async => registerPostgres(),
);
