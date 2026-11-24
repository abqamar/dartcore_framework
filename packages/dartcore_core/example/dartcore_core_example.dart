// Configuration and typed exceptions from dartcore_core (no server needed).
//
// Observed output of `dart run example/dartcore_core_example.dart`:
//
//   name  = Demo
//   port  = 9090
//   flag  = true
//   env   = development
//   other = default
//   require -> ConfigurationException: Missing required configuration "DOES_NOT_EXIST".
//   NotFoundException status = 404

import 'dart:io';

import 'package:dartcore_core/dartcore_core.dart';

Future<void> main() async {
  // Write a throwaway .env so the example is self-contained.
  final dir = Directory.systemTemp.createTempSync('dartcore_core_example');
  File('${dir.path}/.env').writeAsStringSync(
    'APP_NAME=Demo\nAPP_PORT=9090\nFEATURE_X=yes\nAPI_KEY=not-a-real-key\n',
  );

  try {
    // Values are layered: process env wins over .env.<APP_ENV> over .env.
    await Config.load(directory: dir.path);

    print('name  = ${Config.get('APP_NAME')}');
    print('port  = ${Config.getInt('APP_PORT', 8080)}');
    print('flag  = ${Config.getBool('FEATURE_X')}');
    print('env   = ${Config.environment.name}');
    print('other = ${Config.get('MISSING', 'default')}');

    // require() fails loudly instead of returning null.
    try {
      Config.require('DOES_NOT_EXIST');
    } on ConfigurationException catch (e) {
      print('require -> ConfigurationException: ${e.message}');
    }

    // Typed exceptions carry an HTTP status that dartcore_api maps to responses.
    final e = NotFoundException('User not found');
    print('NotFoundException status = ${e.statusCode}');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
