# dartcore_validation

Rule-based request validation for DartCore: nested fields, wildcards, conditional and custom rules, plus async `unique` / `exists` checks.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK. `dartcore_framework` re-exports this package.

## Install

```sh
dart pub add dartcore_validation
```

## Usage

```dart
import 'package:dartcore_validation/dartcore_validation.dart';

final v = Validate.request(data, {
  'name': 'required|string|min:3',
  'email': 'required|email',
  'password': 'required|min:8|confirmed',       // needs password_confirmation
  'address.city': 'required|string',            // nested objects: dot notation
  'items.*.qty': 'required|integer|min:1',      // array wildcards
  'company': 'required_if:type,business',       // conditional
});

if (v.fails) {
  print(v.errors);        // {email: [The email must be a valid email address.]}
} else {
  final clean = v.validated;           // only fields that had rules
  final name = v.get<String>('name');  // typed access
}
v.orThrow();              // or throw ValidationException (HTTP 422 in dartcore_api)
```

Custom rules and custom messages:

```dart
final even = Rule.custom((value, ctx) => (value as int).isEven ? null : 'Must be even.', name: 'even');
Validate.request(data, {'n': ['integer', even]},
    messages: {'email.required': 'We need your email!'});
```

`unique:table,column` and `exists:table,column` are async and need `Validate.requestAsync` with an existence checker
(`databaseExistenceChecker` in `dartcore_framework`).

A runnable program is in [`example/`](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_validation/example/dartcore_validation_example.dart).

## Status and limits

Pre-1.0: the API may change. An unknown rule name throws `ArgumentError` rather than passing silently. The synchronous API throws
`StateError` for `unique`/`exists` instead of skipping them. `regex:` patterns in string form cannot contain `|`; use a `Rule` object.
Reading `validated` on a failed result throws. Full rule list: [validation guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/validation.md).
