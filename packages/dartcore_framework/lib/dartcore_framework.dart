/// DartCore: a simple, modular backend SDK for Dart.
///
/// ```dart
/// import 'package:dartcore_framework/dartcore_framework.dart';
///
/// Future<void> main() async {
///   final app = DartCore();
///   app.get('/hello', (request) => Response.ok({'hello': 'world'}));
///   await app.start(port: 8080);
/// }
/// ```
///
/// Database adapters are separate packages so you install only what you use
/// (`dartcore_postgres`, `dartcore_mysql`, `dartcore_sqlite`) and register
/// them once, e.g. `registerPostgres()`.
library;

export 'package:dartcore_api/dartcore_api.dart';
export 'package:dartcore_core/dartcore_core.dart';
export 'package:dartcore_db/dartcore_db.dart';
export 'package:dartcore_logging/dartcore_logging.dart';
export 'package:dartcore_validation/dartcore_validation.dart';

export 'src/dartcore_app.dart';
export 'src/db_validation.dart';
