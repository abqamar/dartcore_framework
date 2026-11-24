/// Developer-facing explanation of a SQLite failure.
class SqliteDiagnosis {
  const SqliteDiagnosis({this.details, this.hint});
  final String? details;
  final String? hint;
}

/// Maps a SQLite primary result code and message to diagnostics. The real
/// reason is in the message ("table users already exists", "UNIQUE constraint
/// failed: users.email"); the hint adds the likely cause.
SqliteDiagnosis diagnoseSqliteError({
  required int resultCode,
  required String message,
  String? explanation,
}) {
  final lower = message.toLowerCase();
  final details = [
    '[$resultCode] $message',
    if (explanation != null && explanation.isNotEmpty && explanation != message)
      explanation,
  ].join('; ');

  String? hint;
  if (lower.contains('already exists')) {
    hint =
        'An object with this name already exists. If this ran as part of a '
        'migration, it may have run partially.';
  } else if (lower.contains('no such table')) {
    hint = 'The table does not exist. Run your migrations.';
  } else if (lower.contains('no such column') ||
      lower.contains('has no column named')) {
    hint = 'The column does not exist. Check the column name and migrations.';
  } else if (lower.contains('unique constraint failed') ||
      lower.contains('primary key')) {
    hint =
        'Unique violation: a row with the same value in a unique column or '
        'primary key already exists.';
  } else if (lower.contains('not null constraint failed')) {
    hint = 'Not-null violation: a required column was given no value (NULL).';
  } else if (lower.contains('foreign key constraint failed')) {
    hint =
        'Foreign key violation: the referenced row does not exist, or the row '
        'is still referenced by another table.';
  } else if (lower.contains('syntax error')) {
    hint = 'The SQL statement has a syntax error.';
  } else if (resultCode == 5 || resultCode == 6) {
    hint =
        'The database is locked by another connection or process. Retry, or '
        'raise the busy_timeout_ms option.';
  } else if (resultCode == 8) {
    hint =
        'The database file is read-only. Check file and directory permissions.';
  }
  return SqliteDiagnosis(details: details, hint: hint);
}

/// Hint for failing to open the database file.
String diagnoseSqliteOpenError(int resultCode, String path) =>
    switch (resultCode) {
      14 =>
        'Cannot open "$path". Check that the directory exists and is writable '
            'by this process.',
      8 => '"$path" is read-only. Check file and directory permissions.',
      26 => '"$path" is not a SQLite database (or is encrypted/corrupt).',
      _ => 'Check the database path "$path" and its permissions.',
    };
