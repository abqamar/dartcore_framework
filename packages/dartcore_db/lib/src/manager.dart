import 'package:dartcore_core/dartcore_core.dart';

import 'adapter.dart';
import 'compiler.dart';
import 'config.dart';
import 'dialect.dart';
import 'pooled_adapter.dart';
import 'query_builder.dart';
import 'results.dart';

export 'pooled_adapter.dart' show PooledAdapter;

/// Operations available on a connection and inside a transaction.
abstract mixin class DatabaseOperations {
  DatabaseExecutor get executor;
  SqlDialect get dialect;

  /// Starts a query against [name].
  QueryBuilder table(String name, {String primaryKey = 'id'}) =>
      QueryBuilder(executor, dialect, name, primaryKey: primaryKey);

  /// **Advanced**: runs raw SQL with `?` placeholders and returns rows.
  /// Always pass values through [bindings]; never interpolate them.
  Future<List<Row>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) async =>
      (await executor.execute(SqlCompiler(dialect).raw(sql, bindings))).rows;

  /// **Advanced**: runs raw SQL (INSERT/UPDATE/DDL) and returns affected rows.
  Future<int> statement(
    String sql, [
    List<Object?> bindings = const [],
  ]) async => (await executor.execute(
    SqlCompiler(dialect).raw(sql, bindings),
  )).affectedRows;
}

/// A handle to one named connection (a pool).
class Database with DatabaseOperations {
  Database(this.name, this.adapter, this.config);

  final String name;
  final DatabaseAdapter adapter;
  final ConnectionConfig config;

  @override
  DatabaseExecutor get executor => adapter;
  @override
  SqlDialect get dialect => adapter.dialect;
  DatabaseDriver get driver => config.driver;

  /// Runs [action] atomically: commits on success, rolls back and rethrows on
  /// any exception. Never spans multiple databases.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) =>
      adapter.transaction((exec) => action(Transaction._(exec, dialect)));

  Future<bool> ping() => adapter.ping();
  Future<void> disconnect() => adapter.disconnect();
}

/// A transaction scope. Use it instead of the outer [Database] for every
/// query that must be part of the transaction.
class Transaction with DatabaseOperations {
  Transaction._(this._exec, this.dialect, [this._depth = 0]);

  final DatabaseExecutor _exec;
  final int _depth;

  @override
  final SqlDialect dialect;
  @override
  DatabaseExecutor get executor => _exec;

  /// Nested transaction implemented with a SAVEPOINT. If [action] throws, only
  /// the work since the savepoint is rolled back and the exception is rethrown.
  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) async {
    final name = 'dc_sp_${_depth + 1}';
    await _exec.execute(CompiledQuery(dialect.savepointSql(name)));
    try {
      final result = await action(Transaction._(_exec, dialect, _depth + 1));
      final release = dialect.releaseSavepointSql(name);
      if (release != null) await _exec.execute(CompiledQuery(release));
      return result;
    } catch (_) {
      await _exec.execute(CompiledQuery(dialect.rollbackToSavepointSql(name)));
      rethrow;
    }
  }
}

/// Owns named connections. Instances are independent, so tests and
/// multi-database apps never share global state unless they use [DB].
class DatabaseManager with DatabaseOperations {
  DatabaseManager({Map<DatabaseDriver, DriverRegistration>? drivers})
    : _drivers = {...registeredDrivers, ...?drivers};

  /// Process-wide driver registry populated by adapter packages
  /// (e.g. `registerPostgres()`); it only holds stateless factories.
  static final Map<DatabaseDriver, DriverRegistration> registeredDrivers = {};

  static void registerDriver(DatabaseDriver driver, DriverRegistration reg) =>
      registeredDrivers[driver] = reg;

  final Map<DatabaseDriver, DriverRegistration> _drivers;
  final Map<String, Database> _connections = {};
  String? _default;

  Iterable<String> get connectionNames => _connections.keys;

  /// Connects and registers [config] under [name]. The first connection
  /// becomes the default unless [makeDefault] says otherwise.
  Future<Database> connect(
    ConnectionConfig config, {
    String name = 'default',
    bool? makeDefault,
  }) async {
    final reg = _drivers[config.driver];
    if (reg == null) {
      throw ConfigurationException(
        'No adapter registered for "${config.driver.name}". Add the '
        'dartcore_${config.driver.name} package and call its register function '
        '(e.g. registerPostgres()) before connecting.',
      );
    }
    if (_connections.containsKey(name)) {
      throw ConfigurationException('Connection "$name" already exists.');
    }
    final size = reg.poolSizeFor?.call(config) ?? config.maxPoolSize;
    final adapter = PooledAdapter(config, reg, maxPoolSize: size);
    await adapter.connect();
    final db = Database(name, adapter, config);
    _connections[name] = db;
    if (makeDefault ?? _default == null) _default = name;
    return db;
  }

  /// Registers an already-built adapter (custom adapters, test doubles).
  Future<Database> useAdapter(
    DatabaseAdapter adapter,
    ConnectionConfig config, {
    String name = 'default',
    bool? makeDefault,
  }) async {
    await adapter.connect();
    final db = Database(name, adapter, config);
    _connections[name] = db;
    if (makeDefault ?? _default == null) _default = name;
    return db;
  }

  Database connection([String? name]) {
    final n = name ?? _default;
    if (n == null) {
      throw ConfigurationException(
        'No database connection. Call DB.connect(...) first.',
      );
    }
    return _connections[n] ??
        (throw ConfigurationException('Unknown connection "$n".'));
  }

  Database get defaultConnection => connection();

  @override
  DatabaseExecutor get executor => defaultConnection.executor;
  @override
  SqlDialect get dialect => defaultConnection.dialect;

  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) =>
      defaultConnection.transaction(action);

  Future<void> disconnect([String? name]) async {
    if (name != null) {
      await _connections.remove(name)?.disconnect();
      if (_default == name) {
        _default = _connections.isEmpty ? null : _connections.keys.first;
      }
      return;
    }
    final all = _connections.values.toList();
    _connections.clear();
    _default = null;
    for (final c in all) {
      await c.disconnect();
    }
  }
}

/// Convenient static facade over a managed default [DatabaseManager].
///
/// ```dart
/// await DB.connect(driver: DatabaseDriver.sqlite, database: 'app.sqlite');
/// final users = await DB.table('users').where('active', true).get();
/// ```
///
/// Swap the instance with [DB.use] (tests) and release with [DB.disconnect].
abstract final class DB {
  static DatabaseManager _manager = DatabaseManager();

  static DatabaseManager get manager => _manager;
  static void use(DatabaseManager manager) => _manager = manager;

  /// Disconnects everything and installs a fresh manager.
  static Future<void> reset() async {
    final old = _manager;
    _manager = DatabaseManager();
    await old.disconnect();
  }

  static Future<Database> connect({
    required DatabaseDriver driver,
    String host = 'localhost',
    int? port,
    required String database,
    String? username,
    String? password,
    SslMode ssl = SslMode.disable,
    int maxPoolSize = 10,
    Duration queryTimeout = const Duration(seconds: 30),
    Duration connectTimeout = const Duration(seconds: 10),
    String name = 'default',
    bool? makeDefault,
    Map<String, Object?> options = const {},
  }) => _manager.connect(
    ConnectionConfig(
      driver: driver,
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
      ssl: ssl,
      maxPoolSize: maxPoolSize,
      queryTimeout: queryTimeout,
      connectTimeout: connectTimeout,
      options: options,
    ),
    name: name,
    makeDefault: makeDefault,
  );

  static Future<Database> connectWith(
    ConnectionConfig config, {
    String name = 'default',
    bool? makeDefault,
  }) => _manager.connect(config, name: name, makeDefault: makeDefault);

  static Database connection([String? name]) => _manager.connection(name);
  static QueryBuilder table(String name, {String primaryKey = 'id'}) =>
      _manager.table(name, primaryKey: primaryKey);
  static Future<T> transaction<T>(Future<T> Function(Transaction tx) action) =>
      _manager.transaction(action);
  static Future<List<Row>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _manager.select(sql, bindings);
  static Future<int> statement(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _manager.statement(sql, bindings);
  static Future<void> disconnect([String? name]) => _manager.disconnect(name);
}
