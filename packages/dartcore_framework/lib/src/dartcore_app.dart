import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';

/// The DartCore application: HTTP [App] plus a database manager.
///
/// * Works without any database: just don't connect one.
/// * `app.database.table('users')` and the static `DB.table('users')` use the
///   same managed instance (the global [DB.manager] unless you pass your own).
/// * Pass a dedicated [DatabaseManager] to isolate tests or run several apps
///   in one process.
class DartCore extends App {
  /// Creates an app. Without [config], settings come from `Config`
  /// (`APP_NAME`, `APP_ENV`, `APP_PORT`, ...), falling back to defaults.
  DartCore({
    AppConfig? config,
    DatabaseManager? database,
    super.logger,
    bool closeDatabaseOnStop = true,
  }) : database = database ?? DB.manager,
       super(config: config ?? AppConfig.fromConfig(Config.instance)) {
    if (closeDatabaseOnStop) {
      onShutdown(() => this.database.disconnect());
    }
  }

  /// The database manager used by this app (`app.database.table('users')`).
  final DatabaseManager database;
}
