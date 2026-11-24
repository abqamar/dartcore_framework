import 'dart:io';

import 'environment.dart';
import 'exceptions.dart';

/// A source of configuration values (a `.env` file, a secret manager, ...).
///
/// Implement this to load production secrets from Vault, AWS Secrets Manager,
/// Docker secrets, etc. instead of relying on `.env` files.
abstract interface class ConfigSource {
  Future<Map<String, String>> load();
}

/// Reads a dotenv-formatted file. A missing file yields an empty map.
class DotEnvSource implements ConfigSource {
  DotEnvSource(this.path);
  final String path;

  @override
  Future<Map<String, String>> load() async {
    final file = File(path);
    if (!await file.exists()) return {};
    return parseDotEnv(await file.readAsString());
  }
}

/// Reads Docker/Kubernetes style secret files: one file per key in [directory].
class DirectorySecretSource implements ConfigSource {
  DirectorySecretSource(this.directory);
  final String directory;

  @override
  Future<Map<String, String>> load() async {
    final dir = Directory(directory);
    if (!await dir.exists()) return {};
    final out = <String, String>{};
    await for (final e in dir.list()) {
      if (e is File) {
        out[e.uri.pathSegments.last] = (await e.readAsString()).trim();
      }
    }
    return out;
  }
}

/// Parses dotenv text: `KEY=value`, `export KEY=value`, quotes, `#` comments
/// and `\n` escapes inside double quotes. `${OTHER}` is not interpolated.
Map<String, String> parseDotEnv(String text) {
  final out = <String, String>{};
  for (var line in text.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"')) {
      final end = value.lastIndexOf('"');
      value = value
          .substring(1, end > 0 ? end : value.length)
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\"', '"');
    } else if (value.length >= 2 && value.startsWith("'")) {
      final end = value.lastIndexOf("'");
      value = value.substring(1, end > 0 ? end : value.length);
    } else {
      final hash = value.indexOf(' #');
      if (hash >= 0) value = value.substring(0, hash).trimRight();
    }
    out[key] = value;
  }
  return out;
}

/// A typed, layered key/value configuration store.
///
/// Precedence (highest first): explicit [set] overrides, process environment,
/// extra [ConfigSource]s (later sources win), `.env.<environment>`, `.env`.
class ConfigRepository {
  ConfigRepository({Map<String, String>? environment})
    : _environment = environment;

  final Map<String, String>? _environment;
  final Map<String, String> _values = {};
  final Map<String, String> _overrides = {};

  Map<String, String> get _process => _environment ?? Platform.environment;

  /// Loads `.env` and `.env.<APP_ENV>` from [directory] plus [sources].
  Future<void> load({
    String directory = '.',
    String fileName = '.env',
    List<ConfigSource> sources = const [],
  }) async {
    _values.clear();
    _values.addAll(await DotEnvSource('$directory/$fileName').load());
    final env = _process['APP_ENV'] ?? _values['APP_ENV'];
    if (env != null) {
      _values.addAll(await DotEnvSource('$directory/$fileName.$env').load());
    }
    for (final s in sources) {
      _values.addAll(await s.load());
    }
  }

  void set(String key, Object? value) {
    if (value == null) {
      _overrides.remove(key);
    } else {
      _overrides[key] = value.toString();
    }
  }

  bool has(String key) => _lookup(key) != null;

  String? _lookup(String key) =>
      _overrides[key] ?? _process[key] ?? _values[key];

  String? get(String key, [String? defaultValue]) =>
      _lookup(key) ?? defaultValue;

  /// Like [get] but throws [ConfigurationException] when missing.
  String require(String key) =>
      _lookup(key) ??
      (throw ConfigurationException('Missing required configuration "$key".'));

  bool getBool(String key, [bool defaultValue = false]) {
    final v = _lookup(key)?.trim().toLowerCase();
    if (v == null || v.isEmpty) return defaultValue;
    if (const {'1', 'true', 'yes', 'on'}.contains(v)) return true;
    if (const {'0', 'false', 'no', 'off'}.contains(v)) return false;
    throw ConfigurationException('Configuration "$key" is not a boolean.');
  }

  int getInt(String key, [int defaultValue = 0]) {
    final v = _lookup(key);
    if (v == null || v.trim().isEmpty) return defaultValue;
    return int.tryParse(v.trim()) ??
        (throw ConfigurationException(
          'Configuration "$key" is not an integer.',
        ));
  }

  double getDouble(String key, [double defaultValue = 0]) {
    final v = _lookup(key);
    if (v == null || v.trim().isEmpty) return defaultValue;
    return double.tryParse(v.trim()) ??
        (throw ConfigurationException('Configuration "$key" is not a number.'));
  }

  AppEnvironment get environment =>
      AppEnvironment.parse(_lookup('APP_ENV') ?? 'development');
}

/// Static facade over a managed default [ConfigRepository].
///
/// ```dart
/// await Config.load();
/// final port = Config.getInt('APP_PORT', 8080);
/// ```
///
/// Tests can swap the instance with [Config.use] and restore it with
/// [Config.reset].
abstract final class Config {
  static ConfigRepository _instance = ConfigRepository();

  static ConfigRepository get instance => _instance;
  static void use(ConfigRepository repository) => _instance = repository;
  static void reset() => _instance = ConfigRepository();

  static Future<void> load({
    String directory = '.',
    String fileName = '.env',
    List<ConfigSource> sources = const [],
  }) => _instance.load(
    directory: directory,
    fileName: fileName,
    sources: sources,
  );

  static String? get(String key, [String? defaultValue]) =>
      _instance.get(key, defaultValue);
  static String require(String key) => _instance.require(key);
  static bool has(String key) => _instance.has(key);
  static bool getBool(String key, [bool defaultValue = false]) =>
      _instance.getBool(key, defaultValue);
  static int getInt(String key, [int defaultValue = 0]) =>
      _instance.getInt(key, defaultValue);
  static double getDouble(String key, [double defaultValue = 0]) =>
      _instance.getDouble(key, defaultValue);
  static void set(String key, Object? value) => _instance.set(key, value);
  static AppEnvironment get environment => _instance.environment;
}
