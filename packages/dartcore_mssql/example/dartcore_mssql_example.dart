// Connects to Microsoft SQL Server using DB_* values from the environment or a
// .env file, then runs a trivial query.
//
// NOTE: this example needs a running SQL Server and was only analyzed
// (`dart analyze`) while writing it; it was not executed against a server.
// What WAS run without a server: connecting to a closed port, which prints
// the reason and hint (see test/mssql_adapter_test.dart).
//
// Example .env (keep real credentials out of version control):
//
//   DB_DRIVER=mssql
//   DB_HOST=localhost
//   DB_PORT=1433
//   DB_DATABASE=app
//   DB_USERNAME=app
//   DB_PASSWORD=change-me
//   DB_SSL=require          # encrypts; "disable" would send the login unencrypted

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_mssql/dartcore_mssql.dart';

Future<void> main() async {
  await Config.load(); // .env, then .env.<APP_ENV>; process env wins
  registerMssql();

  await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));
  try {
    final rows = await DB.select('SELECT 1 AS one');
    print('connected, SELECT 1 -> ${rows.first['one']}');
  } finally {
    await DB.disconnect();
  }
}
