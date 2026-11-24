# dartcore_core

Typed exceptions and layered configuration (`.env` files, environment variables, secret directories) for DartCore backend applications.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. Most apps import the umbrella package `dartcore_framework`, which re-exports this one.

## Install

```sh
dart pub add dartcore_core
```

## Usage

```dart
import 'package:dartcore_core/dartcore_core.dart';

Future<void> main() async {
  await Config.load();                       // .env, then .env.<APP_ENV>; process env wins
  final port = Config.getInt('APP_PORT', 8080);
  final debug = Config.getBool('APP_DEBUG');
  final secret = Config.require('JWT_SECRET'); // throws ConfigurationException if missing

  print(Config.environment.name);            // development | testing | staging | production
}
```

External secrets (for example mounted files) can be layered in:

```dart
await Config.load(sources: [DirectorySecretSource('/run/secrets')]);
```

Exceptions carry an HTTP status that `dartcore_api` turns into a response:
`ValidationException` (422), `AuthenticationException` (401), `AuthorizationException` (403),
`NotFoundException` (404), `HttpStatusException(status, message)`, plus
`ConfigurationException`, `DatabaseException`, `ConnectionException` and `QueryException`.

A complete, runnable program is in [`example/`](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_core/example/dartcore_core_example.dart).

## Status and limits

Pre-1.0: the API may change between minor versions. An unknown `APP_ENV` value is treated as `production`.
See the [implementation status](https://github.com/abqamar/dartcore_framework/blob/main/docs/status.md) and the
[getting started guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/getting-started.md) for the list of configuration keys.
