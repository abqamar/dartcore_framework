import 'dart:io';

import 'package:dartcore_cli/dartcore_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await DartCoreCli().run(args);
}
