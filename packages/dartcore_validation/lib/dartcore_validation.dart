/// Rule-based validation for request data.
///
/// ```dart
/// final v = Validate.request(data, {
///   'name': 'required|string|min:3',
///   'email': 'required|email',
/// });
/// if (v.fails) return Response.validationError(v.errors);
/// ```
library;

export 'src/validator.dart';
