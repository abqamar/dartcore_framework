import 'dart:io';

import 'package:path/path.dart' as p;

import 'deploy_templates.dart';
import 'templates.dart';

/// Validated settings for the generated `deploy/` files.
class DeploySettings {
  DeploySettings({
    required this.name,
    required this.user,
    required this.port,
    this.domain = '',
  });

  final String name, user, domain;
  final int port;

  static final _unixName = RegExp(r'^[a-z][a-z0-9_-]{0,30}$');
  static final _hostname = RegExp(
    r'^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
  );

  /// Throws [ArgumentError] with a user-facing message for hostile or invalid
  /// values: these end up inside a shell script and systemd/nginx files.
  factory DeploySettings.validated({
    required String name,
    String? user,
    required String port,
    String? domain,
  }) {
    if (!_unixName.hasMatch(name)) {
      throw ArgumentError(
        'Invalid --name "$name": use lowercase letters, digits, "_" or "-", starting with a letter (max 31 characters).',
      );
    }
    final u = user ?? name;
    if (!_unixName.hasMatch(u)) {
      throw ArgumentError(
        'Invalid --user "$u": use lowercase letters, digits, "_" or "-", starting with a letter (max 31 characters).',
      );
    }
    final n = int.tryParse(port);
    if (n == null || n < 1 || n > 65535) {
      throw ArgumentError('Invalid --port "$port": use 1-65535.');
    }
    final d = (domain ?? '').trim();
    if (d.isNotEmpty && !_hostname.hasMatch(d)) {
      throw ArgumentError(
        'Invalid --domain "$d": expected a host name like api.example.com.',
      );
    }
    return DeploySettings(name: name, user: u, port: n, domain: d);
  }

  /// Contents of every generated file, keyed by file name inside `deploy/`.
  Map<String, String> files() {
    final vars = {
      'name': name,
      'user': user,
      'port': '$port',
      'domain': domain,
      'serverName': domain.isEmpty ? '_' : domain,
      'domainOrExample': domain.isEmpty ? 'api.example.com' : domain,
    };
    return {
      '$name.service': render(systemdUnitT, vars),
      'nginx.conf': render(nginxConfT, vars),
      'install.sh': render(installScriptT, vars),
      'README.md': render(deployReadmeT, vars),
    };
  }
}

/// Writes the deploy files into `<root>/deploy`. Existing files are kept
/// unless [force]; those are reported through [skipped]. Returns the paths
/// that were written.
List<String> writeDeployFiles(
  Directory root,
  DeploySettings s, {
  bool force = false,
  List<String>? skipped,
}) {
  final dir = Directory(p.join(root.path, 'deploy'))
    ..createSync(recursive: true);
  final written = <String>[];
  for (final e in s.files().entries) {
    final f = File(p.join(dir.path, e.key));
    if (f.existsSync() && !force) {
      skipped?.add(f.path);
      continue;
    }
    f.writeAsStringSync(e.value);
    if (e.key == 'install.sh' && !Platform.isWindows) {
      Process.runSync('chmod', ['755', f.path]);
    }
    written.add(f.path);
  }
  return written;
}

/// True when the project uses SQLite, which `dart compile exe` cannot build
/// (the `sqlite3` package needs a native build hook).
bool usesSqlite(Directory root) {
  final yaml = File(p.join(root.path, 'dartcore.yaml'));
  if (yaml.existsSync() &&
      RegExp(
        r'^database:\s*sqlite\s*$',
        multiLine: true,
      ).hasMatch(yaml.readAsStringSync())) {
    return true;
  }
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return false;
  // Only the project's own `dependencies:` block counts: the framework lists
  // dartcore_sqlite itself, and dependency_overrides name every package.
  final block = RegExp(
    r'^dependencies:[ \t]*\r?\n((?:[ \t]+.*\r?\n?|[ \t]*\r?\n)*)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  return block != null &&
      RegExp(
        r'^\s+(dartcore_sqlite|sqlite3):',
        multiLine: true,
      ).hasMatch(block.group(1)!);
}

String formatBytes(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).toStringAsFixed(0)} KB';
