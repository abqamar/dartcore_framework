import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:tasks_api/controllers/task_controller.dart';
import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:tasks_api/auth/auth.dart';

/// Registers every route. Called by `bin/server.dart` and `dartcore route:list`.
void registerRoutes(DartCore app) {
  app.get(
    '/health',
    (request) => Response.success({'status': 'ok'}),
    name: 'health',
  );

  app.group(
    '/api',
    middleware: [Auth.middleware()],
    routes: () {
      final tasks = TaskController();
      app.get('/tasks', tasks.index, name: 'tasks.index');
      app.post('/tasks', tasks.store, name: 'tasks.store');
      app.get('/tasks/:id', tasks.show, name: 'tasks.show');
      app.put('/tasks/:id', tasks.update, name: 'tasks.update');
      app.delete('/tasks/:id', tasks.destroy, name: 'tasks.destroy');
    },
  );

  registerAuthRoutes(app);
}
