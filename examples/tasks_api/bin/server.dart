import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:tasks_api/config/database.dart';
import 'package:tasks_api/routes/api.dart';
import 'package:tasks_api/auth/auth.dart';

Future<void> main() async {
  await Config.load();
  await connectDatabase();
  await configureAuth();

  final app = DartCore();
  app.use(const SecurityHeadersMiddleware());
  app.use(
    RateLimitMiddleware(maxRequests: 300, duration: const Duration(minutes: 1)),
  );

  registerRoutes(app);
  await app.start();
}
