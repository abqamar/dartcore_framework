import 'package:dartcore_core/dartcore_core.dart';

enum DatabaseDriver {
  postgres(5432),
  mysql(3306),
  mssql(1433),
  sqlite(null);

  const DatabaseDriver(this.defaultPort);
  final int? defaultPort;

  static DatabaseDriver parse(String value) {
    final v = value.trim().toLowerCase();
    switch (v) {
      case 'postgres' || 'postgresql' || 'pgsql' || 'pg':
        return postgres;
      case 'mysql' || 'mariadb':
        return mysql;
      case 'mssql' || 'sqlserver':
        return mssql;
      case 'sqlite' || 'sqlite3':
        return sqlite;
    }
    throw ConfigurationException('Unknown database driver "$value".');
  }
}

enum SslMode {
  /// No TLS.
  disable,

  /// TLS, certificate not verified (encrypts only).
  require,

  /// TLS with certificate verification (system trust store).
  verifyFull,
}

/// Immutable connection settings. Passwords are never included in
/// [toString].
class ConnectionConfig {
  const ConnectionConfig({
    required this.driver,
    this.host = 'localhost',
    int? port,
    required this.database,
    this.username,
    this.password,
    this.ssl = SslMode.disable,
    this.maxPoolSize = 10,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 5),
    this.acquireTimeout = const Duration(seconds: 30),
    this.options = const {},
  }) : _port = port,
       assert(maxPoolSize > 0);

  /// Reads `<prefix>DRIVER`, `HOST`, `PORT`, `DATABASE`, `USERNAME`,
  /// `PASSWORD`, `SSL` (disable|require|verify-full), `POOL_MAX`,
  /// `CONNECT_TIMEOUT`, `QUERY_TIMEOUT` (seconds) from [config].
  factory ConnectionConfig.fromConfig(
    ConfigRepository config, {
    String prefix = 'DB_',
  }) {
    final driver = DatabaseDriver.parse(config.require('${prefix}DRIVER'));
    final ssl = switch (config.get('${prefix}SSL', 'disable')!.toLowerCase()) {
      'require' || 'true' => SslMode.require,
      'verify-full' || 'verifyfull' => SslMode.verifyFull,
      _ => SslMode.disable,
    };
    return ConnectionConfig(
      driver: driver,
      host: config.get('${prefix}HOST', 'localhost')!,
      port: config.has('${prefix}PORT') ? config.getInt('${prefix}PORT') : null,
      database: config.require('${prefix}DATABASE'),
      username: config.get('${prefix}USERNAME'),
      password: config.get('${prefix}PASSWORD'),
      ssl: ssl,
      maxPoolSize: config.getInt('${prefix}POOL_MAX', 10),
      connectTimeout: Duration(
        seconds: config.getInt('${prefix}CONNECT_TIMEOUT', 10),
      ),
      queryTimeout: Duration(
        seconds: config.getInt('${prefix}QUERY_TIMEOUT', 30),
      ),
    );
  }

  final DatabaseDriver driver;
  final String host;
  final int? _port;
  final String database;
  final String? username;
  final String? password;
  final SslMode ssl;
  final int maxPoolSize;
  final Duration connectTimeout;
  final Duration queryTimeout;
  final Duration idleTimeout;
  final Duration acquireTimeout;

  /// Driver-specific settings (documented per adapter).
  final Map<String, Object?> options;

  int? get port => _port ?? driver.defaultPort;

  ConnectionConfig copyWith({int? maxPoolSize}) => ConnectionConfig(
    driver: driver,
    host: host,
    port: _port,
    database: database,
    username: username,
    password: password,
    ssl: ssl,
    maxPoolSize: maxPoolSize ?? this.maxPoolSize,
    connectTimeout: connectTimeout,
    queryTimeout: queryTimeout,
    idleTimeout: idleTimeout,
    acquireTimeout: acquireTimeout,
    options: options,
  );

  @override
  String toString() =>
      'ConnectionConfig(${driver.name}://${username ?? ''}@$host:$port/$database)';
}
