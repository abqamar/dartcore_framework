import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mysql/dartcore_mysql.dart';

import 'migrations_contract.dart';

void main() => runMigrationContract(
  'MySql',
  const ConnectionConfig(
    driver: DatabaseDriver.mysql,
    host: '127.0.0.1',
    port: 33069,
    database: 'dartcore_test',
    username: 'root',
    password: 'dartcore',
  ),
  () async => registerMySql(),
);
