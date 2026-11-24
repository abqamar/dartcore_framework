import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;

/// Developer-facing explanation of a failure: [details] is the real reason,
/// [hint] one actionable sentence. Never contains the password.
class PgDiagnosis {
  const PgDiagnosis({this.details, this.hint});
  final String? details;
  final String? hint;
}

const _queryHints = <String, String>{
  '42P07':
      'An object with this name already exists. If this ran as part of a '
      'migration, the migrations may have run partially, or the connecting '
      'user cannot read the migrations table so it re-ran them.',
  '42501':
      'The database user lacks privileges on this object. Check object '
      'ownership and GRANTs for the user in your DB_USERNAME setting.',
  '23505':
      'Unique violation: a row with the same value in a unique column or '
      'primary key already exists.',
  '23503':
      'Foreign key violation: the referenced row does not exist, or the row '
      'is still referenced by another table.',
  '23502': 'Not-null violation: a required column was given no value (NULL).',
  '42P01':
      'The table does not exist. Run your migrations, and check the schema '
      'and search_path.',
  '42703': 'The column does not exist. Check the column name and migrations.',
  '3D000':
      'The database does not exist. Create it, or fix the database name in '
      'your configuration.',
  '28P01':
      'Authentication failed. Check the username and password in your '
      'configuration.',
};

String _redact(String s, String? password) =>
    (password == null || password.isEmpty) ? s : s.replaceAll(password, '***');

/// Builds diagnostics for a failed query from plain values (a
/// `pg.ServerException`'s fields), so it can be tested without a server.
PgDiagnosis diagnosePostgresQueryError({
  String? sqlState,
  required String message,
  String? detail,
  String? hint,
  String? schemaName,
  String? tableName,
  String? columnName,
  String? constraintName,
}) {
  final parts = <String>[
    '${sqlState == null ? '' : '[$sqlState] '}$message',
    if (detail != null && detail.isNotEmpty) 'detail: $detail',
    if (hint != null && hint.isNotEmpty) 'server hint: $hint',
    if (schemaName != null) 'schema: $schemaName',
    if (tableName != null) 'table: $tableName',
    if (columnName != null) 'column: $columnName',
    if (constraintName != null) 'constraint: $constraintName',
  ];
  return PgDiagnosis(details: parts.join('; '), hint: _queryHints[sqlState]);
}

PgDiagnosis diagnosePostgresServerException(pg.ServerException e) =>
    diagnosePostgresQueryError(
      sqlState: e.code,
      message: e.message,
      detail: e.detail,
      hint: e.hint,
      schemaName: e.schemaName,
      tableName: e.tableName,
      columnName: e.columnName,
      constraintName: e.constraintName,
    );

/// Classifies a failure from `pg.Connection.open`. [sqlState] defaults to the
/// code of a `pg.ServerException`. [password], if given, is scrubbed from the
/// output.
PgDiagnosis diagnosePostgresConnectError(
  Object error, {
  required String host,
  required int port,
  required String database,
  String? username,
  String? password,
  String? sqlState,
}) {
  final state = sqlState ?? (error is pg.ServerException ? error.code : null);
  final raw = error is pg.PgException ? error.message : error.toString();
  final text = _redact(raw, password);
  final lower = text.toLowerCase();
  final at = '$host:$port';
  PgDiagnosis d(String hint) =>
      PgDiagnosis(details: state == null ? text : '[$state] $text', hint: hint);

  if (lower.contains('role') && lower.contains('does not exist')) {
    return d(
      'Role "${username ?? ''}" does not exist on the server. Create the '
      'user (CREATE ROLE) or fix the username.',
    );
  }
  if (state == '28P01' || state == '28000' || lower.contains('password auth')) {
    return d(
      'Authentication failed for user "${username ?? ''}". Check the '
      'username and password; for a role without a password, check '
      'pg_hba.conf.',
    );
  }
  if (state == '3D000') {
    return d(
      'Database "$database" does not exist on $at. Create it '
      '(CREATE DATABASE) or fix the database name.',
    );
  }
  if (RegExp(r'\b(ssl|tls)\b').hasMatch(lower)) {
    return d(
      'SSL negotiation failed. If the server requires SSL use ssl: '
      'SslMode.require; if it does not support SSL use SslMode.disable.',
    );
  }
  if (error is pg.BadCertificateException ||
      error is HandshakeException ||
      lower.contains('certificate')) {
    return d(
      'The server certificate was rejected. Check the server certificate, or '
      'use a less strict SslMode (not recommended in production).',
    );
  }
  if (error is TimeoutException ||
      lower.contains('timed out') ||
      lower.contains('timeout')) {
    return d(
      'Timed out connecting to $at. Check the host and port, firewall or '
      'security-group rules, and whether the server is reachable from here.',
    );
  }
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname') ||
        lower.contains('name or service not known') ||
        lower.contains('no address associated')) {
      return d(
        'The host "$host" could not be resolved (DNS). Check the spelling of '
        'DB_HOST and the DNS/network of this machine.',
      );
    }
    if (lower.contains('connection refused') ||
        const {111, 61, 10061}.contains(code)) {
      return d(
        'Postgres is not listening on $at - is it running? If it runs in '
        'Docker, check the published port. Try DB_HOST=127.0.0.1 instead of '
        'localhost (IPv6 vs IPv4).',
      );
    }
    if (lower.contains('no route') || lower.contains('unreachable')) {
      return d('$at is unreachable. Check the network, VPN and firewall.');
    }
  }
  return PgDiagnosis(
    details: state == null ? text : '[$state] $text',
    hint:
        'Check that Postgres is running and reachable at $at and that the '
        'credentials and database name are correct.',
  );
}
