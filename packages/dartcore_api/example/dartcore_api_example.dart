// Starts a DartCore App on an ephemeral port, calls it once per route with dart:io HttpClient, shuts down.
//
// Observed output of `dart run example/dartcore_api_example.dart`:
//
//   GET /hello/world -> 200 {"success":true,"message":"Success","data":{"greeting":"Hello, world!"},"meta":null}
//   POST /echo -> 201 {"a":1}
//   GET /missing -> 404 {"success":false,"message":"No such thing"}

import 'dart:convert';
import 'dart:io';

import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_logging/dartcore_logging.dart';

Future<void> main() async {
  final app = App(
    config: const AppConfig(environment: AppEnvironment.testing),
    logger: Logger(level: LogLevel.error),
  );

  app.get(
    '/hello/:name',
    (request) =>
        Response.success({'greeting': 'Hello, ${request.param('name')}!'}),
  );
  app.post('/echo', (request) async => Response.created(await request.json()));
  app.get('/missing', (request) => throw NotFoundException('No such thing'));

  // Port 0 asks the OS for a free port.
  await app.start(port: 0, handleSignals: false);
  final port = app.port!;
  final client = HttpClient();

  try {
    Future<void> show(String method, String path, [Object? body]) async {
      final req = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      print(
        '$method $path -> ${res.statusCode} ${await res.transform(utf8.decoder).join()}',
      );
    }

    await show('GET', '/hello/world');
    await show('POST', '/echo', {'a': 1});
    await show('GET', '/missing');
  } finally {
    client.close();
    await app.stop();
  }
}
