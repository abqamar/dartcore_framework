import 'config.dart';
import 'dialect.dart';
import 'results.dart';

/// Anything that can run a compiled query: an adapter, or a transaction.
abstract interface class DatabaseExecutor {
  Future<QueryResult> execute(CompiledQuery query);
}

/// What an adapter honestly supports. Used by docs, tests and by features that
/// must refuse rather than emulate.
class AdapterCapabilities {
  const AdapterCapabilities({
    this.pooling = true,
    this.transactions = true,
    this.savepoints = true,
    this.returning = false,
    this.preparedStatements = true,
    this.streaming = false,
  });

  final bool pooling;
  final bool transactions;
  final bool savepoints;
  final bool returning;
  final bool preparedStatements;
  final bool streaming;
}

/// One live connection to a database, implemented by driver packages.
///
/// Implementations must: bind parameters natively (never interpolate),
/// convert driver exceptions into `QueryException` / `ConnectionException`,
/// and convert driver types into plain Dart values (`num`, `String`, `bool`,
/// `DateTime`, `List<int>`, `Map`).
abstract interface class DriverConnection implements DatabaseExecutor {
  bool get isOpen;
  Future<bool> ping();
  Future<void> close();
}

typedef ConnectionOpener =
    Future<DriverConnection> Function(ConnectionConfig config);

/// Describes a driver so [DatabaseManager] can build adapters from it.
class DriverRegistration {
  const DriverRegistration({
    required this.dialect,
    required this.capabilities,
    required this.open,
    this.poolSizeFor,
  });

  final SqlDialect dialect;
  final AdapterCapabilities capabilities;
  final ConnectionOpener open;

  /// Overrides the pool size for engines that need it (in-memory SQLite must
  /// use a single connection).
  final int Function(ConnectionConfig config)? poolSizeFor;
}

/// Pool-level contract used by the query builder and managers.
abstract interface class DatabaseAdapter implements DatabaseExecutor {
  SqlDialect get dialect;
  AdapterCapabilities get capabilities;

  Future<void> connect();
  Future<void> disconnect();

  @override
  Future<QueryResult> execute(CompiledQuery query);

  /// Runs [action] on a single dedicated connection inside BEGIN/COMMIT.
  /// Commits on success; rolls back and rethrows on failure.
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor tx) action);

  Future<bool> ping();
}
