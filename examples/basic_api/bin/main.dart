import 'package:dartcore_framework/dartcore_framework.dart';

/// Run: `dart run bin/main.dart`, then `curl localhost:8080/hello/Dart`.
Future<void> main() async {
  final app = DartCore(config: const AppConfig(port: 8080));

  app.use(CorsMiddleware());
  app.use(const SecurityHeadersMiddleware());

  app.get('/hello/:name', (request) {
    return Response.success({
      'greeting': 'Hello, ${request.param('name')}!',
    }, message: 'Greeting generated');
  });

  app.post('/echo', (request) async {
    final v = Validate.request(await request.json(), {
      'message': 'required|string|min:1|max:200',
    });
    if (v.fails) return Response.validationError(v.errors);
    return Response.ok({'you_said': v.get<String>('message')});
  });

  await app.start();
}
