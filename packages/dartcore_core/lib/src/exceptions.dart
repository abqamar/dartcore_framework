/// Base class for every exception thrown by DartCore.
///
/// [message] is written to be safe to show to API clients. Internal details
/// (SQL, driver messages, stack traces) belong in [cause], [details] and
/// [hint]; none of these are serialized into HTTP responses by DartCore
/// (they appear in [toString], which is what logs and consoles show).
class DartCoreException implements Exception {
  DartCoreException(
    this.message, {
    this.code,
    this.cause,
    this.statusCode = 500,
    this.details,
    this.hint,
  });

  final String message;
  final String? code;
  final Object? cause;

  /// HTTP status code used when this exception reaches the HTTP layer.
  final int statusCode;

  /// Developer-facing diagnostics (driver message, table/column/constraint,
  /// SQLSTATE...). For logs and consoles only: never sent to API clients.
  final String? details;

  /// One actionable sentence for the developer. Same audience as [details].
  final String? hint;

  @override
  String toString() {
    final b = StringBuffer('$runtimeType: $message');
    final d = details;
    if (d != null && d.isNotEmpty) {
      b.write('\n  Details: $d');
    }
    final h = hint;
    if (h != null && h.isNotEmpty) {
      b.write('\n  Hint: $h');
    }
    return b.toString();
  }
}

class ConfigurationException extends DartCoreException {
  ConfigurationException(
    super.message, {
    super.code,
    super.cause,
    super.details,
    super.hint,
  }) : super(statusCode: 500);
}

class DatabaseException extends DartCoreException {
  DatabaseException(
    super.message, {
    super.code,
    super.cause,
    super.details,
    super.hint,
  }) : super(statusCode: 500);
}

class ConnectionException extends DatabaseException {
  ConnectionException(
    super.message, {
    super.code,
    super.cause,
    super.details,
    super.hint,
  });
}

/// A query failed. [sql] is kept for logging; bound parameters are
/// deliberately not stored because they may contain sensitive data.
class QueryException extends DatabaseException {
  QueryException(
    super.message, {
    this.sql,
    super.code,
    super.cause,
    super.details,
    super.hint,
  });

  final String? sql;
}

class ValidationException extends DartCoreException {
  ValidationException(this.errors, {String message = 'Validation failed'})
    : super(message, statusCode: 422);

  /// Field name to list of human-readable messages.
  final Map<String, List<String>> errors;
}

class AuthenticationException extends DartCoreException {
  AuthenticationException([super.message = 'Unauthenticated', Object? cause])
    : super(statusCode: 401, cause: cause);
}

class AuthorizationException extends DartCoreException {
  AuthorizationException([super.message = 'Forbidden'])
    : super(statusCode: 403);
}

class NotFoundException extends DartCoreException {
  NotFoundException([super.message = 'Not found']) : super(statusCode: 404);
}

/// An error with an explicit HTTP status (400, 405, 408, 413, 429...).
class HttpStatusException extends DartCoreException {
  HttpStatusException(
    int status,
    super.message, {
    this.headers = const {},
    super.code,
  }) : super(statusCode: status);

  final Map<String, String> headers;
}
