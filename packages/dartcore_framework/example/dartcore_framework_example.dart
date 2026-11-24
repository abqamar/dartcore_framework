// DartCore app with validation and SQLite, exercised in-process with app.send (ran for real).
//
// Observed output of `dart run example/dartcore_framework_example.dart`:
//
//   GET /hello/world -> 200 {"success":true,"message":"Success","data":{"greeting":"Hello, world!"},"meta":null}
//   POST /notes -> 201 {"id":1,"text":"first note"}
//   POST /notes -> 422 {"success":false,"message":"Validation failed","errors":{"text":["The text field is required."]}}
//   GET /notes -> 200 [{"id":1,"text":"first note"}]

import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

Future<void> main() async {
  registerSqlite();
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
  await DB.statement(
    'CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL)',
  );

  final app = DartCore(
    config: const AppConfig(environment: AppEnvironment.testing),
    logger: Logger(level: LogLevel.error),
  );

  app.get(
    '/hello/:name',
    (request) =>
        Response.success({'greeting': 'Hello, ${request.param('name')}!'}),
  );
  app.get('/notes', (r) async => Response.ok(await DB.table('notes').get()));
  app.post('/notes', (r) async {
    final v = Validate.request(await r.json(), {
      'text': 'required|string|max:500',
    });
    if (v.fails) return Response.validationError(v.errors);
    return Response.created(await DB.table('notes').insert(v.validated));
  });

  // app.send() runs the full pipeline without a socket (handy in tests).
  Future<void> show(String method, String path, [Object? body]) async {
    final res = await app.send(method, path, body: body);
    print('$method $path -> ${res.statusCode} ${await res.readText()}');
  }

  await show('GET', '/hello/world');
  await show('POST', '/notes', {'text': 'first note', 'ignored': 'dropped'});
  await show('POST', '/notes', {'text': ''});
  await show('GET', '/notes');

  // For a real server: await app.start(port: 8080);
  await DB.reset();
}
