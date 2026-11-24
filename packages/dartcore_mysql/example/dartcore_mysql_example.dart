// Connects to a MySQL server using DB_* values from the environment or a .env
// file, then runs a trivial query.
//
// NOTE: this example needs a running MySQL server and was only analyzed
// (`dart analyze`) while writing it; it was not executed against a server.
//
// Example .env (keep real credentials out of version control):
//
//   DB_DRIVER=mysql
//   DB_HOST=localhost
//   DB_PORT=3306
//   DB_DATABASE=app
//   DB_USERNAME=app
//   DB_PASSWORD=change-me
//   DB_SSL=disable

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mysql/dartcore_mysql.dart';

Future<void> main() async {
  await Config.load(); // .env, then .env.<APP_ENV>; process env wins
  registerMySql();

  await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));
  try {
    final rows = await DB.select('SELECT 1 AS one');
    print('connected, SELECT 1 -> ${rows.first['one']}');
  } finally {
    await DB.disconnect();
  }
}
