import 'dart:async';
import 'dart:io';

/// Developer-facing explanation of a failure. Never contains the password.
class SqlServerDiagnosis {
  const SqlServerDiagnosis({this.details, this.hint});
  final String? details;
  final String? hint;
}

/// Hints for common SQL Server error numbers (`sys.messages`).
const _queryHints = <int, String>{
  2714:
      'An object with that name already exists. If this ran as part of a '
      'migration, it may have run partially (DDL is committed as it goes) or '
      'the migrations table is unreadable to this user.',
  2627: 'Unique or primary key violation: that value already exists.',
  2601: 'Duplicate key: a unique index already contains that value.',
  515: 'Not-null violation: a required column was given no value (NULL).',
  547:
      'Constraint violation: a foreign key (or check) rejected this change. '
      'Either the referenced row does not exist, or the row is still '
      'referenced by another table.',
  208:
      'The table or view does not exist. Run your migrations and check the '
      'database and schema (default schema is dbo).',
  207: 'The column does not exist. Check the column name and your migrations.',
  102: 'Syntax error near the reported text. Check the SQL.',
  156: 'Syntax error near the reported keyword. Check the SQL.',
  229:
      'The SQL Server login lacks permission on this object. Check your '
      'GRANTs (and who owns the schema).',
  230: 'The SQL Server login lacks permission on this column.',
  262: 'The SQL Server login may not create tables here. Check your GRANTs.',
  245: 'A value could not be converted to the column type. Check the data.',
  2628:
      'A string value is longer than the column allows (it would be '
      'truncated). Shorten it or widen the column.',
  8152:
      'A string value is longer than the column allows (it would be '
      'truncated). Shorten it or widen the column.',
  1205:
      'This statement was chosen as a deadlock victim and rolled back. '
      'Retry the transaction.',
  1222: 'A lock timed out. Another transaction holds a conflicting lock.',
  334:
      'OUTPUT INSERTED cannot be used on a table with enabled triggers. '
      'Insert without it and read the row back, or use OUTPUT INTO.',
};

String _redact(String s, String? password) =>
    (password == null || password.isEmpty) ? s : s.replaceAll(password, '***');

/// Diagnostics for a failed query from the server's error [number] and [text].
SqlServerDiagnosis diagnoseSqlServerQueryError({
  required int number,
  required String text,
  int? severity,
  int? state,
}) {
  final tail = [
    if (severity != null) 'severity $severity',
    if (state != null) 'state $state',
  ].join(', ');
  return SqlServerDiagnosis(
    details: '[$number] $text${tail.isEmpty ? '' : ' ($tail)'}',
    hint: _queryHints[number],
  );
}

/// Classifies a failure while connecting. [number] is set for server errors
/// (login failures and friends). [password] is scrubbed from the output.
SqlServerDiagnosis diagnoseSqlServerConnectError(
  Object error, {
  required String host,
  required int? port,
  required String database,
  String? username,
  String? password,
  int? number,
  String? message,
}) {
  final text = _redact(message ?? error.toString(), password);
  final lower = text.toLowerCase();
  final at = '$host:${port ?? 1433}';
  final details = number == null || number == 0 ? text : '[$number] $text';
  SqlServerDiagnosis d(String hint) =>
      SqlServerDiagnosis(details: details, hint: hint);

  if (number == 18456 || lower.contains('login failed')) {
    return d(
      'Login failed for "${username ?? ''}". Check the username and '
      'password, and that SQL Server authentication (not only Windows '
      'authentication) is enabled on the server.',
    );
  }
  if (number == 4060 || lower.contains('cannot open database')) {
    return d(
      'The login cannot open database "$database". Check the name, that it '
      'exists, and that the login is mapped to a user in it.',
    );
  }
  if (error is TimeoutException || lower.contains('timed out')) {
    return d(
      'Timed out connecting to $at. Check the host and port, firewall rules '
      'and that TCP/IP is enabled for the instance.',
    );
  }
  // The driver wraps socket failures in its own exception type, so match on
  // the text (and on the OS error code when it is a SocketException).
  if (lower.contains('failed host lookup') ||
      lower.contains('nodename nor servname') ||
      lower.contains('name or service not known') ||
      lower.contains('no such host') ||
      lower.contains('no address associated')) {
    return d(
      'The host "$host" could not be resolved (DNS). Check DB_HOST and the '
      'network of this machine.',
    );
  }
  if (lower.contains('connection refused') ||
      lower.contains('errno = 111') ||
      lower.contains('errno = 61') ||
      lower.contains('errno = 10061') ||
      (error is SocketException &&
          const {111, 61, 10061}.contains(error.osError?.errorCode))) {
    return d(
      'Nothing is listening on $at. Is SQL Server running with TCP/IP '
      'enabled? Check the port (default 1433). For a named instance use '
      'the "instance" option, which asks the SQL Server Browser (UDP 1434). '
      'Try DB_HOST=127.0.0.1 instead of localhost (IPv6 vs IPv4).',
    );
  }
  if (lower.contains('certificate') ||
      lower.contains('tls') ||
      lower.contains('ssl') ||
      lower.contains('handshake')) {
    return d(
      'The secure connection failed. SQL Server commonly uses a self-signed '
      'certificate: use ssl: SslMode.require (encrypts without verifying the '
      'server), or give the CA with the "ca_file" option and use '
      'SslMode.verifyFull. SslMode.disable sends the login unencrypted.',
    );
  }
  return d(
    'Check that SQL Server is running and reachable at $at, that TCP/IP is '
    'enabled, and that the credentials and database name are correct.',
  );
}
