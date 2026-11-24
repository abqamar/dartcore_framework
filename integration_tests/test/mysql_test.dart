import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mysql/dartcore_mysql.dart';

import 'contract.dart';

void main() {
  runContract(
    EngineSpec(
      name: 'MySQL',
      config: const ConnectionConfig(
        driver: DatabaseDriver.mysql,
        host: '127.0.0.1',
        port: 33069,
        database: 'dartcore_test',
        username: 'root',
        password: 'dartcore',
        maxPoolSize: 5,
      ),
      idColumn: 'INT AUTO_INCREMENT PRIMARY KEY',
      boolType: 'TINYINT(1)',
      dropIfExists: (t) => 'DROP TABLE IF EXISTS $t',
    ),
    register: () async => registerMySql(),
  );
}
