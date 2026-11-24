import 'dart:convert';

/// Encodes [value] as JSON, understanding `DateTime`, `Duration`, `BigInt`,
/// objects with `toJson()`, and `Set`/`Iterable`.
String encodeJson(Object? value) =>
    jsonEncode(value, toEncodable: _toEncodable);

Object? _toEncodable(Object? o) {
  if (o is DateTime) return o.toUtc().toIso8601String();
  if (o is BigInt) return o.toString();
  if (o is Duration) return o.inMilliseconds;
  if (o is Iterable) return o.toList();
  if (o is Map) return {for (final e in o.entries) e.key.toString(): e.value};
  try {
    return (o as dynamic).toJson();
  } on NoSuchMethodError {
    throw JsonUnsupportedObjectError(
      o,
      cause:
          'Add a toJson() method to ${o.runtimeType} to return it from a handler.',
    );
  }
}
