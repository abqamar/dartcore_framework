import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum CheckStatus { ok, warn, fail }

/// One line of `dartcore doctor` output. Messages never contain secret values.
class Check {
  const Check(this.status, this.title, this.message, {this.fix});
  final CheckStatus status;
  final String title;
  final String message;
  final String? fix;

  String format() {
    final label = switch (status) {
      CheckStatus.ok => 'OK  ',
      CheckStatus.warn => 'WARN',
      CheckStatus.fail => 'FAIL',
    };
    final b = StringBuffer('$label  $title: $message');
    if (fix != null && status != CheckStatus.ok) b.write('\n      Fix: $fix');
    return b.toString();
  }
}

/// Minimal dotenv parser, same rules as DartCore's `parseDotEnv` for the cases
/// that matter here (`KEY=value`, `export`, quotes, `#` comments).
Map<String, String> parseEnv(String text) {
  final out = <String, String>{};
  for (var line in const LineSplitter().convert(text)) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith('"') || value.startsWith("'")) &&
        value.endsWith(value[0])) {
      value = value.substring(1, value.length - 1);
    } else {
      final hash = value.indexOf(' #');
      if (hash >= 0) value = value.substring(0, hash).trimRight();
    }
    out[key] = value;
  }
  return out;
}

bool _isPlaceholder(String? v) {
  final t = (v ?? '').trim().toLowerCase();
  return t.isEmpty || t == 'change_me' || t == 'changeme';
}

/// The file-based checks of `dartcore doctor` (no database, no processes).
/// [env] is `null` when `.env` could not be used.
class ProjectChecks {
  ProjectChecks(this.root);
  final Directory root;

  Map<String, String>? env;
  bool authEnabled = false;
  String driver = '';

  File get _envFile => File(p.join(root.path, '.env'));

  List<Check> run() {
    final out = <Check>[];
    final yaml = File(p.join(root.path, 'dartcore.yaml'));
    if (yaml.existsSync()) {
      final text = yaml.readAsStringSync();
      authEnabled = RegExp(r'^auth:\s*true', multiLine: true).hasMatch(text);
    }
    out.add(
      Check(CheckStatus.ok, 'Project', 'dartcore.yaml found in ${root.path}.'),
    );
    final envCheck = _envFileCheck();
    out.add(envCheck);
    if (env == null) return out;
    driver = (env!['DB_DRIVER'] ?? '').toLowerCase();
    out.addAll(_keyChecks());
    out.addAll(_appEnvChecks());
    out.add(_storageCheck());
    return out;
  }

  Check _envFileCheck() {
    final type = FileSystemEntity.typeSync(_envFile.path);
    if (type == FileSystemEntityType.notFound) {
      return const Check(
        CheckStatus.fail,
        '.env',
        'no .env file in the project root.',
        fix: 'run: cp .env.example .env   and fill in the values.',
      );
    }
    if (type == FileSystemEntityType.directory) {
      return const Check(
        CheckStatus.fail,
        '.env',
        '.env is a directory, not a file (DartCore silently ignores it, so no setting is loaded).',
        fix:
            'remove the directory (rmdir .env) and create the file: cp .env.example .env',
      );
    }
    try {
      env = parseEnv(_envFile.readAsStringSync());
    } on FileSystemException catch (e) {
      return Check(
        CheckStatus.fail,
        '.env',
        'cannot read .env (${e.osError?.message ?? e.message}).',
        fix: 'check the file permissions (chmod 600 .env).',
      );
    }
    return Check(
      CheckStatus.ok,
      '.env',
      'regular file with ${env!.length} key(s).',
    );
  }

  List<Check> _keyChecks() {
    final e = env!;
    final out = <Check>[];
    final production = _isProduction(e['APP_ENV']);

    // Database keys.
    final required = driver == 'sqlite'
        ? ['DB_DRIVER', 'DB_DATABASE']
        : ['DB_DRIVER', 'DB_HOST', 'DB_DATABASE', 'DB_USERNAME'];
    final bad = <String>[];
    for (final k in required) {
      if (_isPlaceholder(e[k])) bad.add(k);
    }
    if (bad.isEmpty) {
      out.add(
        const Check(
          CheckStatus.ok,
          'Database settings',
          'all required DB_* keys are set.',
        ),
      );
    } else {
      out.add(
        Check(
          CheckStatus.fail,
          'Database settings',
          '${bad.join(', ')} ${bad.length == 1 ? 'is' : 'are'} missing, empty or still CHANGE_ME.',
          fix: 'set real values in .env (see .env.example).',
        ),
      );
    }
    if (driver != 'sqlite') {
      final pw = e['DB_PASSWORD'];
      if (pw != null && pw.trim().toLowerCase().startsWith('change')) {
        out.add(
          const Check(
            CheckStatus.fail,
            'DB_PASSWORD',
            'is still a CHANGE_ME placeholder.',
            fix: 'set the real database password in .env.',
          ),
        );
      } else if (_isPlaceholder(pw)) {
        out.add(
          Check(
            production ? CheckStatus.fail : CheckStatus.warn,
            'DB_PASSWORD',
            'is empty.',
            fix: production
                ? 'set the database password in .env.'
                : 'fine for a local database without a password; set one for anything shared.',
          ),
        );
      }
    }

    // JWT secret.
    final jwt = e['JWT_SECRET'];
    final needed = authEnabled || production;
    if (_isPlaceholder(jwt)) {
      out.add(
        Check(
          needed ? CheckStatus.fail : CheckStatus.warn,
          'JWT_SECRET',
          'is missing, empty or a placeholder.',
          fix: 'generate one: openssl rand -base64 48   and put it in .env.',
        ),
      );
    } else {
      final bytes = utf8.encode(jwt!).length;
      if (bytes < 32) {
        out.add(
          Check(
            CheckStatus.fail,
            'JWT_SECRET',
            'is only $bytes bytes; at least 32 are required.',
            fix: 'generate one: openssl rand -base64 48   and put it in .env.',
          ),
        );
      } else {
        out.add(Check(CheckStatus.ok, 'JWT_SECRET', 'set ($bytes bytes).'));
      }
    }
    return out;
  }

  bool _isProduction(String? appEnv) {
    // Mirrors AppEnvironment.parse: unknown values count as production.
    return switch (appEnv?.trim().toLowerCase()) {
      null || '' => false,
      'development' || 'dev' || 'local' => false,
      'testing' || 'test' => false,
      'staging' || 'stage' => false,
      _ => true,
    };
  }

  List<Check> _appEnvChecks() {
    final e = env!;
    final out = <Check>[];
    final appEnv = e['APP_ENV'];
    final production = _isProduction(appEnv);
    if (!production) {
      out.add(
        Check(
          CheckStatus.ok,
          'APP_ENV',
          '${appEnv == null || appEnv.isEmpty ? 'not set (defaults to development)' : appEnv}.',
        ),
      );
      return out;
    }
    final known = {'production', 'prod'}.contains(appEnv!.trim().toLowerCase());
    if (!known) {
      out.add(
        Check(
          CheckStatus.warn,
          'APP_ENV',
          '"$appEnv" is not a known environment, so it is treated as production.',
          fix: 'use development, testing, staging or production.',
        ),
      );
    }
    final issues = <String>[];
    for (final entry in e.entries) {
      if (entry.key.contains('CORS') && entry.value.trim() == '*') {
        issues.add('${entry.key}=* allows any website to call the API');
      }
    }
    if (_sourceAllowsAnyOrigin()) {
      issues.add('CorsMiddleware with "*" found in lib/ or bin/');
    }
    if ((e['APP_DEBUG'] ?? '').toLowerCase() == 'true') {
      issues.add('APP_DEBUG=true exposes error details');
    }
    if ((e['APP_TRUST_PROXY'] ?? '').isEmpty) {
      issues.add(
        'APP_TRUST_PROXY is not set (set it to true only when every request passes through your nginx/load balancer)',
      );
    }
    if (issues.isEmpty) {
      out.add(const Check(CheckStatus.ok, 'Production settings', 'look sane.'));
    } else {
      out.add(
        Check(
          CheckStatus.warn,
          'Production settings',
          issues.join('; '),
          fix:
              'review these values in .env / your CORS setup before going live.',
        ),
      );
    }
    return out;
  }

  bool _sourceAllowsAnyOrigin() {
    for (final dir in ['lib', 'bin']) {
      final d = Directory(p.join(root.path, dir));
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final t = f.readAsStringSync();
        if (t.contains('CorsMiddleware') &&
            RegExp(r'''['"]\*['"]''').hasMatch(t)) {
          return true;
        }
      }
    }
    return false;
  }

  Check _storageCheck() {
    final configured = env!['STORAGE_PATH'];
    final String path;
    if (configured != null && configured.isNotEmpty) {
      path = p.isAbsolute(configured)
          ? configured
          : p.join(root.path, configured);
    } else {
      path = p.join(root.path, 'storage');
      if (!Directory(path).existsSync()) {
        return const Check(
          CheckStatus.ok,
          'Storage',
          'no storage directory configured or present; nothing to check.',
        );
      }
    }
    final dir = Directory(path);
    if (!dir.existsSync()) {
      return Check(
        CheckStatus.fail,
        'Storage',
        'directory $path does not exist.',
        fix: 'create it: mkdir -p "$path"',
      );
    }
    final probe = File(
      p.join(path, '.dartcore_doctor_${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      probe.writeAsStringSync('ok');
      probe.deleteSync();
    } on FileSystemException {
      return Check(
        CheckStatus.fail,
        'Storage',
        '$path is not writable by this user.',
        fix: 'fix the permissions: chmod u+w "$path"',
      );
    }
    return Check(CheckStatus.ok, 'Storage', '$path exists and is writable.');
  }

  /// Whether the HTTP port can be bound on this machine.
  Future<Check> portCheck() async {
    final raw = env?['APP_PORT'];
    final port = int.tryParse(raw ?? '') ?? 8080;
    if (port < 0 || port > 65535) {
      return Check(
        CheckStatus.fail,
        'Port',
        'APP_PORT=$port is not a valid port.',
        fix: 'use a number between 1 and 65535.',
      );
    }
    try {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await s.close();
      return Check(CheckStatus.ok, 'Port', '$port is free to bind.');
    } on SocketException catch (e) {
      return Check(
        CheckStatus.warn,
        'Port',
        'cannot bind $port (${e.osError?.message ?? e.message}).',
        fix:
            'stop whatever uses it (your server may already be running), or change APP_PORT.',
      );
    }
  }
}

/// Parses the `OK` / `WARN` / `FAIL` lines printed by the project's
/// `bin/console.dart doctor` (continuation lines are indented).
List<Check> parseConsoleDoctor(String output) {
  final out = <Check>[];
  final lines = const LineSplitter().convert(output);
  final re = RegExp(r'^(OK|WARN|FAIL)\s+([^:]+):\s*(.*)$');
  for (var i = 0; i < lines.length; i++) {
    final m = re.firstMatch(lines[i]);
    if (m == null) continue;
    final status = switch (m[1]) {
      'OK' => CheckStatus.ok,
      'WARN' => CheckStatus.warn,
      _ => CheckStatus.fail,
    };
    final rest = <String>[];
    while (i + 1 < lines.length && lines[i + 1].startsWith('      ')) {
      rest.add(lines[++i].trim());
    }
    String? fix;
    final extra = <String>[];
    for (final r in rest) {
      if (r.startsWith('Fix:')) {
        fix = r.substring(4).trim();
      } else {
        extra.add(r);
      }
    }
    final msg = [m[3]!, ...extra].join(' ');
    out.add(Check(status, m[2]!.trim(), msg, fix: fix));
  }
  return out;
}
