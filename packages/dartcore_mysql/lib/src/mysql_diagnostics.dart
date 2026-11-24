import 'dart:async';
import 'dart:io';

/// Developer-facing explanation of a failure. Never contains the password.
class MySqlDiagnosis {
  const MySqlDiagnosis({this.details, this.hint});
  final String? details;
  final String? hint;
}

const _hints = <int, String>{
  1050:
      'The table already exists. If this ran as part of a migration, it may '
      'have run partially (MySQL DDL is not transactional) or the migrations '
      'table is unreadable to this user.',
  1062: 'Duplicate entry: a unique or primary key value already exists.',
  1048: 'Not-null violation: a required column was given no value (NULL).',
  1364: 'A NOT NULL column without a default value was not given a value.',
  1451: 'Foreign key violation: the row is still referenced by another table.',
  1452: 'Foreign key violation: the referenced row does not exist.',
  1146: 'The table does not exist. Run your migrations and check the database.',
  1054: 'The column does not exist. Check the column name and migrations.',
  1142: 'The MySQL user lacks privileges on this table. Check your GRANTs.',
  1044: 'The MySQL user lacks access to this database. Check your GRANTs.',
  1045:
      'Access denied: check the username and password, and that the user may '
      'connect from this host.',
  1049: 'The database does not exist. Create it or fix the database name.',
};

String _redact(String s, String? password) =>
    (password == null || password.isEmpty) ? s : s.replaceAll(password, '***');

/// Diagnostics for a failed query from the server's [errorCode] and
/// [message] (the driver does not expose the SQLSTATE).
MySqlDiagnosis diagnoseMySqlQueryError({
  required int errorCode,
  required String message,
}) => MySqlDiagnosis(details: '[$errorCode] $message', hint: _hints[errorCode]);

/// Classifies a failure while connecting. [errorCode] is set for server
/// errors (`MySQLServerException`). [password] is scrubbed from the output.
MySqlDiagnosis diagnoseMySqlConnectError(
  Object error, {
  required String host,
  required int port,
  required String database,
  String? username,
  String? password,
  int? errorCode,
  String? message,
}) {
  final text = _redact(message ?? error.toString(), password);
  final lower = text.toLowerCase();
  final at = '$host:$port';
  final details = errorCode == null ? text : '[$errorCode] $text';
  MySqlDiagnosis d(String hint) => MySqlDiagnosis(details: details, hint: hint);

  if (errorCode == 1045) {
    return d(
      'Access denied for user "${username ?? ''}". Check the username and '
      'password, and that the user may connect from this host.',
    );
  }
  if (errorCode == 1049) {
    return d('Database "$database" does not exist. Create it or fix the name.');
  }
  if (errorCode == 1044) {
    return d('User "${username ?? ''}" has no access to database "$database".');
  }
  if (error is TimeoutException || lower.contains('timed out')) {
    return d(
      'Timed out connecting to $at. Check the host and port, firewall rules, '
      'and whether the server is reachable from here.',
    );
  }
  if (error is SocketException) {
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('name or service not known')) {
      return d(
        'The host "$host" could not be resolved (DNS). Check DB_HOST and the '
        'network of this machine.',
      );
    }
    if (lower.contains('connection refused') ||
        const {111, 61, 10061}.contains(error.osError?.errorCode)) {
      return d(
        'MySQL is not listening on $at - is it running? If it runs in '
        'Docker, check the published port. Try DB_HOST=127.0.0.1 instead of '
        'localhost (IPv6 vs IPv4).',
      );
    }
  }
  if (lower.contains('caching_sha2') || lower.contains('public key')) {
    return d(
      'The server requires a secure channel or public key retrieval. Use '
      'ssl: SslMode.require, or set the allow_public_key_retrieval option.',
    );
  }
  if (lower.contains('ssl') || lower.contains('tls')) {
    return d(
      'Secure connection failed. Match ssl to what the server supports '
      '(SslMode.require / SslMode.disable).',
    );
  }
  return d(
    'Check that MySQL is running and reachable at $at and that the '
    'credentials and database name are correct.',
  );
}
