import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'deploy.dart';
import 'doctor.dart';
import 'names.dart';
import 'templates.dart';

const cliVersion = '0.1.0';

class CliException implements Exception {
  CliException(this.message, {this.exitCode = 1});
  final String message;
  final int exitCode;
}

/// Runs a process with the terminal attached; returns its exit code.
typedef ProcessStarter =
    Future<int> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
      Map<String, String> environment,
    );

/// Runs a process and captures its output.
typedef ProcessCapture =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      String workingDirectory,
    );

Future<int> _inheritStdio(
  String exe,
  List<String> args,
  String dir,
  Map<String, String> env,
) async {
  final proc = await Process.start(
    exe,
    args,
    workingDirectory: dir,
    environment: env,
    mode: ProcessStartMode.inheritStdio,
  );
  return proc.exitCode;
}

Future<ProcessResult> _capture(String exe, List<String> args, String dir) =>
    Process.run(exe, args, workingDirectory: dir);

class _Db {
  const _Db(
    this.key,
    this.label,
    this.pkg,
    this.register,
    this.port,
    this.user,
  );
  final String key, label, pkg, register, port, user;
}

const _databases = {
  'postgres': _Db(
    'postgres',
    'PostgreSQL',
    'postgres',
    'registerPostgres',
    '5432',
    'postgres',
  ),
  'mysql': _Db('mysql', 'MySQL', 'mysql', 'registerMySql', '3306', 'root'),
  'sqlite': _Db('sqlite', 'SQLite', 'sqlite', 'registerSqlite', '', ''),
  'supabase': _Db(
    'postgres',
    'Supabase (direct PostgreSQL connection)',
    'postgres',
    'registerPostgres',
    '5432',
    'postgres',
  ),
  'mssql': _Db('mssql', 'SQL Server', 'mssql', 'registerMssql', '1433', 'sa'),
};

const _architectures = ['simple', 'mvc', 'clean', 'modular'];

/// Where generated files go for each architecture.
class _Layout {
  _Layout(this.arch);
  final String arch;

  String dir(String kind, {String? module}) {
    switch (arch) {
      case 'clean':
        return switch (kind) {
          'controller' => 'lib/presentation/controllers',
          'middleware' => 'lib/presentation/middleware',
          'model' => 'lib/data/models',
          'service' => 'lib/domain/services',
          'resource' => 'lib/presentation/resources',
          'validator' => 'lib/presentation/validators',
          _ => 'lib/$kind',
        };
      case 'modular':
        final m = module ?? 'app';
        return switch (kind) {
          'middleware' => 'lib/shared/middleware',
          _ => 'lib/modules/$m/${kind}s',
        };
      default:
        return switch (kind) {
          'controller' => 'lib/controllers',
          'middleware' => 'lib/middleware',
          'model' => 'lib/models',
          'service' => 'lib/services',
          'resource' => 'lib/resources',
          'validator' => 'lib/validators',
          _ => 'lib/$kind',
        };
    }
  }
}

/// The `dartcore` command line.
class DartCoreCli {
  DartCoreCli({
    StringSink? out,
    StringSink? err,
    Directory? cwd,
    bool? interactive,
    ProcessStarter? starter,
    ProcessCapture? capture,
  }) : _start = starter ?? _inheritStdio,
       _run = capture ?? _capture,
       _out = out ?? stdout,
       _err = err ?? stderr,
       _cwd = cwd ?? Directory.current,
       _interactive = interactive ?? (stdin.hasTerminal && stdout.hasTerminal);

  final StringSink _out, _err;
  final Directory _cwd;
  final bool _interactive;
  final ProcessStarter _start;
  final ProcessCapture _run;

  static const _help =
      '''
DartCore $cliVersion - a simple, modular backend SDK for Dart

Usage: dartcore <command> [arguments]

Project
  create <name>              Create a new project (--database, --architecture, --auth, --path)
  serve [--port N]           Run the server (bin/server.dart)
  route:list                 List registered routes
  docs:generate              Generate OpenAPI docs (requires dartcore_openapi - not yet available)

Generators
  make:controller <Name>     [--resource --table=users --module=m]
  make:model <Name>          [-m (also migration) --fields=name:string,age:int --soft-deletes]
  make:service <Name>
  make:middleware <Name>
  make:resource <Name>
  make:validator <Name>
  make:migration <name>      e.g. create_users_table
  make:seeder <Name>         [--table=users]

Database
  migrate                    Run pending migrations
  migrate:rollback [--step N]
  migrate:reset | migrate:fresh [--seed]   (destructive: ask for confirmation, or pass --force)
  migrate:status | db:status
  db:seed [--class=Name]

Deployment (no Docker, no Dart on the server)
  doctor                     Check .env, database, migrations, storage and port
  build                      Compile server + console into build/release
                             [--target linux-x64|linux-arm64|host --output DIR --no-console]
  deploy:init                Write deploy/ (systemd unit, nginx site, install.sh)
                             [--name N --domain D --user U --port P --force]

  --version                  Print the version
  --help                     Print this help
''';

  Future<int> run(List<String> args) async {
    try {
      if (args.isEmpty ||
          args.first == '--help' ||
          args.first == '-h' ||
          args.first == 'help') {
        _out.writeln(_help);
        return 0;
      }
      if (args.first == '--version' || args.first == '-v') {
        _out.writeln('dartcore $cliVersion');
        return 0;
      }
      final cmd = args.first;
      final rest = args.sublist(1);
      switch (cmd) {
        case 'create':
          return await _create(rest);
        case 'serve':
          return await _serve(rest);
        case 'route:list' ||
            'migrate' ||
            'migrate:rollback' ||
            'migrate:reset' ||
            'migrate:fresh' ||
            'migrate:status' ||
            'db:status' ||
            'db:seed':
          return await _console(cmd, rest);
        case 'doctor':
          return await _doctor(rest);
        case 'build':
          return await _build(rest);
        case 'deploy:init':
          return _deployInit(rest);
        case 'docs:generate':
          throw CliException(
            'docs:generate needs the dartcore_openapi package, which is not implemented yet. '
            'See docs/openapi.md for the current status.',
          );
        case 'make:controller':
          return _makeController(rest);
        case 'make:model':
          return _makeModel(rest);
        case 'make:service':
          return _makeSimple(rest, 'service', serviceT, 'Service');
        case 'make:middleware':
          return _makeSimple(rest, 'middleware', middlewareT, 'Middleware');
        case 'make:resource':
          return _makeSimple(rest, 'resource', resourceT, 'Resource');
        case 'make:validator':
          return _makeSimple(rest, 'validator', validatorT, 'Validator');
        case 'make:migration':
          return _makeMigration(rest);
        case 'make:seeder':
          return _makeSeeder(rest);
      }
      throw CliException(
        'Unknown command "$cmd". Run "dartcore --help".',
        exitCode: 64,
      );
    } on CliException catch (e) {
      _err.writeln('Error: ${e.message}');
      return e.exitCode;
    } on ArgumentError catch (e) {
      _err.writeln('Error: ${e.message}');
      return 64;
    } on FormatException catch (e) {
      _err.writeln('Error: ${e.message}');
      return 64;
    }
  }

  // ---- create ------------------------------------------------------------------

  Future<int> _create(List<String> args) async {
    final parser = ArgParser()
      ..addOption('database', abbr: 'd', allowed: _databases.keys.toList())
      ..addOption('architecture', abbr: 'a', allowed: _architectures)
      ..addFlag('auth', defaultsTo: null)
      ..addOption(
        'path',
        help:
            'Path to a local DartCore checkout (until packages are on pub.dev)',
      )
      ..addFlag('no-pub-get', negatable: false);
    final r = parser.parse(args);
    if (r.rest.isEmpty) {
      throw CliException(
        'Usage: dartcore create <name> [options]',
        exitCode: 64,
      );
    }
    final name = Names.validated(r.rest.first, 'project name');
    final package = Names.dartPackageName(name);

    final dbKey =
        (r['database'] as String?) ??
        _ask(
          'Database',
          _databases.keys.where((k) => k != 'mssql').toList(),
          'sqlite',
        );
    final arch =
        (r['architecture'] as String?) ??
        _ask('Architecture', _architectures, 'mvc');
    final auth =
        (r['auth'] as bool?) ??
        _confirm('Include authentication (JWT + refresh tokens)?', false);
    final db = _databases[dbKey]!;
    if (db.key == 'mssql') {
      throw CliException(
        'SQL Server has no verified DartCore adapter yet. See docs/database-compatibility.md.',
      );
    }

    final root = Directory(p.join(_cwd.path, name));
    if (root.existsSync() && root.listSync().isNotEmpty) {
      throw CliException(
        'Directory "${root.path}" already exists and is not empty.',
      );
    }

    final rnd = Random.secure();
    final jwtSecret = base64.encode(List.generate(48, (_) => rnd.nextInt(256)));
    final vars = <String, String>{
      'name': name,
      'package': package,
      'driver': db.key,
      'driverPkg': db.pkg,
      'driverLabel': db.label,
      'registerFn': db.register,
      'port': db.port,
      'database': db.key == 'sqlite' ? 'storage/database.sqlite' : package,
      'username': db.user,
      'password': '',
      'ssl': dbKey == 'supabase' ? 'require' : 'disable',
      'jwtSecret': jwtSecret,
      'architecture': arch,
      'auth': '$auth',
      'databaseNote': dbKey == 'supabase'
          ? '\n> **Supabase:** this project connects to your Supabase-hosted PostgreSQL directly. '
                'Supabase Auth, Storage and Realtime are *not* part of DartCore yet.\n'
          : '',
    };

    String dep(String pkg) => r['path'] != null
        ? '  $pkg:\n    path: ${p.join(p.absolute(r['path'] as String), 'packages', pkg)}'
        : '  $pkg: ^$cliVersion';
    final deps = [
      dep('dartcore_framework'),
      dep('dartcore_${db.pkg}'),
      dep('dartcore_migrations'),
      if (auth) dep('dartcore_auth'),
      if (arch != 'simple') dep('dartcore_orm'),
    ].join('\n');
    vars['dependencies'] = deps;
    if (r['path'] != null) {
      // Until the packages are published, every transitive DartCore package must
      // also resolve from the local checkout.
      const all = [
        'dartcore_framework',
        'dartcore_core',
        'dartcore_logging',
        'dartcore_validation',
        'dartcore_db',
        'dartcore_api',
        'dartcore_sqlite',
        'dartcore_postgres',
        'dartcore_mysql',
        'dartcore_migrations',
        'dartcore_auth',
        'dartcore_orm',
        'dartcore_cache',
      ];
      vars['dependencies'] =
          '$deps\n\ndependency_overrides:\n${all.map(dep).join('\n')}';
    }

    void write(String path, String content) {
      final f = File(p.join(root.path, path));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    final pubspec = render(pubspecT, {
      ...vars,
      'dependencies': vars['dependencies']!
          .split('\n\ndependency_overrides:')
          .first,
    });
    final overrides = vars['dependencies']!.contains('dependency_overrides:')
        ? '\ndependency_overrides:${vars['dependencies']!.split('dependency_overrides:').last}\n'
        : '';
    write('pubspec.yaml', pubspec + overrides);
    write('analysis_options.yaml', analysisT);
    write('dartcore.yaml', render(dartcoreYamlT, vars));
    write('.gitignore', gitignoreT);
    write('.env', render(envT, vars));
    write('.env.example', render(envExampleT, vars));
    write('README.md', render(readmeT, vars));
    write('lib/config/database.dart', render(databaseConfigT, vars));
    write('database/migrations/index.dart', migrationsIndexT);
    write('database/seeders/index.dart', seedersIndexT);
    write('bin/console.dart', render(consoleT, vars));
    write(
      'bin/server.dart',
      render(serverT, {
        ...vars,
        'authImport': auth ? "import 'package:$package/auth/auth.dart';\n" : '',
        'authBoot': auth ? '  await configureAuth();\n' : '',
      }),
    );
    if (db.key == 'sqlite') {
      Directory(p.join(root.path, 'storage')).createSync(recursive: true);
    }
    for (final d in ['tests', 'database/migrations', 'database/seeders']) {
      Directory(p.join(root.path, d)).createSync(recursive: true);
    }
    if (auth) write('lib/auth/auth.dart', authT);

    final layout = _Layout(arch);
    final ctrlDir = layout.dir('controller', module: 'users');
    final ctrlImport =
        'package:$package/${ctrlDir.substring(4)}/user_controller.dart';
    write(
      'lib/routes/api.dart',
      render(routesMvcT, {
        'imports':
            "import '$ctrlImport';\n${auth ? "import 'package:dartcore_auth/dartcore_auth.dart';\nimport 'package:$package/auth/auth.dart';\n" : ''}",
        'authRoutes': auth ? '\n  registerAuthRoutes(app);\n' : '',
        // With auth, users are created through /auth/register, and the user list
        // requires a valid token.
        'groupMiddleware': auth ? 'middleware: [Auth.middleware()], ' : '',
        'writeRoutes': auth
            ? ''
            : "    app.post('/users', users.store, name: 'users.store');\n"
                  "    app.put('/users/:id', users.update, name: 'users.update');\n"
                  "    app.delete('/users/:id', users.destroy, name: 'users.destroy');\n",
      }),
    );
    write(
      '$ctrlDir/user_controller.dart',
      _resourceController('UserController', 'users', const {
        'name': 'string',
        'email': 'string',
      }, withPassword: false),
    );

    // users migration (+ password column when auth is on)
    final id = _migrationId('create_users_table');
    final cols = StringBuffer()
      ..writeln("        table.string('name');")
      ..writeln("        table.string('email').unique();");
    if (auth) cols.writeln("        table.string('password');");
    write(
      'database/migrations/$id.dart',
      render(migrationCreateT, {
        'class': 'CreateUsersTable',
        'id': id,
        'table': 'users',
        'columns': cols.toString(),
      }),
    );
    _registerInIndex(
      File(p.join(root.path, 'database/migrations/index.dart')),
      "import '$id.dart';",
      'CreateUsersTable(),',
    );

    // seeder
    write(
      'database/seeders/user_seeder.dart',
      render(seederT, {
        'class': 'UserSeeder',
        'table': 'users',
        'rows': auth
            ? "      {'name': 'Demo', 'email': 'demo@example.com', 'password': r'not-a-real-hash'},\n"
            : "      {'name': 'John', 'email': 'john@example.com'},\n      {'name': 'Jane', 'email': 'jane@example.com'},\n",
      }),
    );
    _registerInIndex(
      File(p.join(root.path, 'database/seeders/index.dart')),
      "import 'user_seeder.dart';",
      'UserSeeder(),',
    );

    _out.writeln('Created ${root.path}');
    if (!(r['no-pub-get'] as bool)) {
      _out.writeln('Running dart pub get ...');
      final res = await Process.run('dart', [
        'pub',
        'get',
      ], workingDirectory: root.path);
      if (res.exitCode != 0) {
        _err.writeln(res.stderr);
        _out.writeln(
          r['path'] == null
              ? 'dart pub get failed: DartCore packages are not on pub.dev yet. Re-run with --path <dartcore checkout>.'
              : 'dart pub get failed.',
        );
        return 1;
      }
    }
    _out.writeln('''

Next steps:
  cd $name
  dartcore migrate
  dartcore serve
''');
    if (auth) {
      _out.writeln(
        'Note: the seeded demo user has no usable password; register via POST /auth/register.',
      );
    }
    return 0;
  }

  String _ask(String question, List<String> options, String def) {
    if (!_interactive) return def;
    _out.write('$question (${options.join('/')}) [$def]: ');
    final a = (stdin.readLineSync() ?? '').trim().toLowerCase();
    if (a.isEmpty) return def;
    if (!options.contains(a)) {
      throw CliException(
        '"$a" is not one of: ${options.join(', ')}.',
        exitCode: 64,
      );
    }
    return a;
  }

  bool _confirm(String question, bool def) {
    if (!_interactive) return def;
    _out.write('$question (y/n) [${def ? 'y' : 'n'}]: ');
    final a = (stdin.readLineSync() ?? '').trim().toLowerCase();
    return a.isEmpty ? def : a.startsWith('y');
  }

  // ---- project commands ----------------------------------------------------------

  Directory _projectRoot() {
    var d = _cwd.absolute;
    while (true) {
      if (File(p.join(d.path, 'dartcore.yaml')).existsSync()) return d;
      if (d.parent.path == d.path) {
        throw CliException(
          'Not inside a DartCore project (no dartcore.yaml found). Run "dartcore create <name>" first.',
        );
      }
      d = d.parent;
    }
  }

  String _setting(Directory root, String key, String def) {
    final text = File(p.join(root.path, 'dartcore.yaml')).readAsStringSync();
    final m = RegExp('^$key:\\s*(\\S+)', multiLine: true).firstMatch(text);
    return m?.group(1) ?? def;
  }

  Future<int> _serve(List<String> args) async {
    final r =
        (ArgParser()
              ..addOption('port', abbr: 'p')
              ..addOption('host'))
            .parse(args);
    final root = _projectRoot();
    final env = <String, String>{
      if (r['port'] != null) 'APP_PORT': _port(r['port'] as String),
      if (r['host'] != null) 'APP_HOST': r['host'] as String,
    };
    return _stream(['run', 'bin/server.dart'], root, env);
  }

  String _port(String v) {
    final n = int.tryParse(v);
    if (n == null || n < 0 || n > 65535) {
      throw CliException('Invalid port "$v".', exitCode: 64);
    }
    return '$n';
  }

  Future<int> _console(String cmd, List<String> args) => _stream(
    ['run', 'bin/console.dart', cmd, ...args],
    _projectRoot(),
    const {},
  );

  Future<int> _stream(
    List<String> dartArgs,
    Directory dir,
    Map<String, String> env,
  ) => _start('dart', dartArgs, dir.path, env);

  // ---- deployment ----------------------------------------------------------------

  String _projectPackageName(Directory root) {
    final f = File(p.join(root.path, 'pubspec.yaml'));
    final m = f.existsSync()
        ? RegExp(
            r'^name:\s*(\S+)',
            multiLine: true,
          ).firstMatch(f.readAsStringSync())
        : null;
    return m?.group(1) ?? p.basename(root.path);
  }

  String _exampleEnvPort(Directory root) {
    final f = File(p.join(root.path, '.env.example'));
    if (!f.existsSync()) return '8080';
    return parseEnv(f.readAsStringSync())['APP_PORT'] ?? '8080';
  }

  int _deployInit(List<String> args) {
    final r =
        (ArgParser()
              ..addOption('name')
              ..addOption('domain')
              ..addOption('user')
              ..addOption('port')
              ..addFlag('force', negatable: false))
            .parse(args);
    final root = _projectRoot();
    final s = DeploySettings.validated(
      name: (r['name'] as String?) ?? _projectPackageName(root),
      user: r['user'] as String?,
      port: (r['port'] as String?) ?? _exampleEnvPort(root),
      domain: r['domain'] as String?,
    );
    final skipped = <String>[];
    final written = writeDeployFiles(
      root,
      s,
      force: r['force'] as bool,
      skipped: skipped,
    );
    for (final f in written) {
      _out.writeln('Created ${p.relative(f, from: _cwd.path)}');
    }
    for (final f in skipped) {
      _out.writeln(
        'Kept ${p.relative(f, from: _cwd.path)} (already exists; use --force to overwrite).',
      );
    }
    _out.writeln(
      '\nNext: dartcore build   (compiles and bundles everything into build/release/)\n'
      'Details: deploy/README.md',
    );
    return 0;
  }

  Future<int> _build(List<String> args) async {
    final r =
        (ArgParser()
              ..addOption(
                'target',
                allowed: ['linux-x64', 'linux-arm64', 'host'],
                defaultsTo: 'linux-x64',
              )
              ..addOption('output', abbr: 'o', defaultsTo: 'build/release')
              ..addFlag('no-console', negatable: false))
            .parse(args);
    final root = _projectRoot();
    final target = r['target'] as String;
    final withConsole = !(r['no-console'] as bool);

    if (usesSqlite(root)) {
      throw CliException(
        'This project uses SQLite, which cannot be compiled to a standalone binary: the sqlite3 package '
        'needs a native build hook that "dart compile exe" does not support.\n'
        'Use PostgreSQL or MySQL for deployments (dartcore create <name> -d postgres), or run the project '
        'from source on the server with "dart run bin/server.dart".',
      );
    }

    final extra = <String>[];
    if (target == 'host') {
      if (!Platform.isLinux) {
        _out.writeln(
          'Warning: --target host builds for ${Platform.operatingSystem}, so the binary will NOT run on an Ubuntu server.',
        );
      }
    } else {
      final help = await _run('dart', ['compile', 'exe', '--help'], root.path);
      if (!'${help.stdout}'.contains('--target-os')) {
        throw CliException(
          'This Dart SDK cannot cross-compile (no --target-os in "dart compile exe --help").\n'
          'Upgrade Dart (3.8 or newer), or run "dartcore build --target host" on a machine with the same '
          'OS and CPU as the server (for example on the Ubuntu server itself or a Linux CI runner).',
        );
      }
      extra.addAll([
        '--target-os',
        'linux',
        '--target-arch',
        target == 'linux-arm64' ? 'arm64' : 'x64',
      ]);
    }

    final example = File(p.join(root.path, '.env.example'));
    if (!example.existsSync()) {
      throw CliException(
        '.env.example is missing in the project root; the install script builds the server .env from it.',
      );
    }
    final outDir = Directory(
      p.isAbsolute(r['output'] as String)
          ? r['output'] as String
          : p.join(root.path, r['output'] as String),
    )..createSync(recursive: true);
    final watch = Stopwatch()..start();

    _out.writeln('[1/4] dart pub get');
    final pub = await _start('dart', ['pub', 'get'], root.path, const {});
    if (pub != 0) throw CliException('"dart pub get" failed (exit code $pub).');

    final binaries = <String>['server', if (withConsole) 'console'];
    _out.writeln(
      '[2/4] Compiling ${binaries.map((b) => 'bin/$b.dart').join(' and ')} for ${target == 'host' ? 'this machine' : target} (this takes a while)',
    );
    for (final bin in binaries) {
      final res = await _run('dart', [
        'compile',
        'exe',
        ...extra,
        'bin/$bin.dart',
        '-o',
        p.join(outDir.path, bin),
      ], root.path);
      if (res.exitCode != 0) {
        _err.writeln('${res.stdout}${res.stderr}'.trim());
        final text = '${res.stdout}${res.stderr}'.toLowerCase();
        throw CliException(
          text.contains('sqlite') || text.contains('hook')
              ? 'Compilation failed because a dependency needs a native build hook (such as sqlite3), which '
                    '"dart compile exe" does not support. Use PostgreSQL or MySQL for deployments.'
              : 'Compiling bin/$bin.dart failed (see the compiler output above).',
        );
      }
    }

    _out.writeln('[3/4] Bundling .env.example');
    example.copySync(p.join(outDir.path, '.env.example'));

    _out.writeln('[4/4] Bundling deploy/');
    final deployDir = Directory(p.join(root.path, 'deploy'));
    final hasUnit =
        deployDir.existsSync() &&
        deployDir.listSync().any((e) => e.path.endsWith('.service'));
    if (!hasUnit) {
      _out.writeln(
        '      deploy/ not found: generating it with defaults (dartcore deploy:init).',
      );
      writeDeployFiles(
        root,
        DeploySettings.validated(
          name: _projectPackageName(root),
          port: _exampleEnvPort(root),
        ),
      );
    }
    final bundleDeploy = Directory(p.join(outDir.path, 'deploy'))
      ..createSync(recursive: true);
    var name = _projectPackageName(root);
    var deployFiles = 0;
    for (final f in deployDir.listSync().whereType<File>()) {
      f.copySync(p.join(bundleDeploy.path, p.basename(f.path)));
      deployFiles++;
      if (f.path.endsWith('.service')) {
        name = p.basenameWithoutExtension(f.path);
      }
    }
    final installSh = p.join(bundleDeploy.path, 'install.sh');
    if (!Platform.isWindows && File(installSh).existsSync()) {
      Process.runSync('chmod', ['755', installSh]);
    }

    final rel = p.relative(outDir.path, from: root.path);
    _out.writeln('\nBuild finished in ${watch.elapsed.inSeconds}s: $rel/');
    for (final bin in binaries) {
      _out.writeln(
        '  ${bin.padRight(14)} ${formatBytes(File(p.join(outDir.path, bin)).lengthSync())}',
      );
    }
    _out.writeln('  ${'.env.example'.padRight(14)} copied');
    _out.writeln('  ${'deploy/'.padRight(14)} $deployFiles files');
    _out.writeln(
      '\nNext (replace user@host with your server; built for $target):\n'
      '  1. rsync -av $rel/ user@host:~/$name-release/\n'
      "  2. ssh -t user@host 'cd ~/$name-release && sudo ./deploy/install.sh --migrate --nginx'\n"
      'Full guide: deploy/README.md',
    );
    return 0;
  }

  Future<int> _doctor(List<String> args) async {
    ArgParser().parse(args);
    final checks = <Check>[];
    final Directory root;
    try {
      root = _projectRoot();
    } on CliException {
      _out.writeln(
        const Check(
          CheckStatus.fail,
          'Project',
          'dartcore.yaml not found in this directory or any parent.',
          fix: 'run doctor inside a project created by "dartcore create".',
        ).format(),
      );
      return 1;
    }
    final pc = ProjectChecks(root);
    checks.addAll(pc.run());

    // Database + migrations: run inside the project with its own adapter.
    final failedConfig = checks.any(
      (c) => c.status == CheckStatus.fail && c.title != 'Storage',
    );
    if (pc.env == null || failedConfig) {
      checks.add(
        const Check(
          CheckStatus.warn,
          'Database connection',
          'skipped because the settings above are not valid.',
          fix: 'fix the FAIL lines and run "dartcore doctor" again.',
        ),
      );
    } else if (!File(
      p.join(root.path, '.dart_tool', 'package_config.json'),
    ).existsSync()) {
      checks.add(
        const Check(
          CheckStatus.warn,
          'Database connection',
          'skipped: dependencies are not installed.',
          fix: 'run: dart pub get',
        ),
      );
    } else {
      final res = await _run('dart', [
        'run',
        'bin/console.dart',
        'doctor',
      ], root.path);
      final parsed = parseConsoleDoctor('${res.stdout}');
      if (parsed.isEmpty) {
        final tail = '${res.stdout}\n${res.stderr}'
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        checks.add(
          Check(
            CheckStatus.fail,
            'Database connection',
            'could not run bin/console.dart doctor: '
                '${tail.reversed.take(3).toList().reversed.join(' | ')}',
            fix:
                'make sure bin/console.dart handles "doctor" (compare it with a freshly generated project) and that the code compiles.',
          ),
        );
      } else {
        checks.addAll(parsed);
      }
    }
    checks.add(await pc.portCheck());

    for (final c in checks) {
      _out.writeln(c.format());
    }
    final fails = checks.where((c) => c.status == CheckStatus.fail).length;
    final warns = checks.where((c) => c.status == CheckStatus.warn).length;
    _out.writeln(
      '\n${checks.length - fails - warns} ok, $warns warning(s), $fails failure(s).',
    );
    return fails == 0 ? 0 : 1;
  }

  // ---- generators ----------------------------------------------------------------

  File _newFile(String relativePath) {
    final f = File(p.join(_projectRoot().path, relativePath));
    if (f.existsSync()) {
      throw CliException(
        '${p.relative(f.path, from: _cwd.path)} already exists; not overwriting.',
      );
    }
    f.parent.createSync(recursive: true);
    return f;
  }

  int _makeSimple(
    List<String> args,
    String kind,
    String template,
    String suffix,
  ) {
    final r = (ArgParser()..addOption('module')).parse(args);
    if (r.rest.isEmpty) {
      throw CliException('Usage: dartcore make:$kind <Name>', exitCode: 64);
    }
    var cls = Names.pascal(Names.validated(r.rest.first, '$kind name'));
    if (!cls.endsWith(suffix)) cls = '$cls$suffix';
    final root = _projectRoot();
    final dir = _Layout(
      _setting(root, 'architecture', 'mvc'),
    ).dir(kind, module: r['module'] as String?);
    final file = _newFile('$dir/${Names.snake(cls)}.dart');
    file.writeAsStringSync(render(template, {'class': cls}));
    _out.writeln('Created ${p.relative(file.path, from: _cwd.path)}');
    return 0;
  }

  String _resourceController(
    String cls,
    String table,
    Map<String, String> fields, {
    required bool withPassword,
  }) {
    String rules(bool update) => fields.entries.map((e) {
      final t = switch (e.value) {
        'int' => 'integer',
        'bool' => 'boolean',
        'double' => 'numeric',
        'datetime' => 'date',
        _ => 'string',
      };
      final req = update ? 'sometimes|' : 'required|';
      return "      '${e.key}': '$req$t${e.key == 'email' ? '|email' : ''}',\n";
    }).join();
    return render(controllerResourceT, {
      'class': cls,
      'table': table,
      'singular': Names.pascal(
        table.endsWith('s') ? table.substring(0, table.length - 1) : table,
      ),
      'label': Names.pascal(table),
      'sortable': ["'id'", ...fields.keys.map((k) => "'$k'")].join(', '),
      'columns': [
        "'id'",
        ...fields.keys.map((k) => "'$k'"),
        "'created_at'",
        "'updated_at'",
      ].join(', '),
      'rules': rules(false),
      'updateRules': rules(true),
    });
  }

  int _makeController(List<String> args) {
    final r =
        (ArgParser()
              ..addFlag('resource', abbr: 'r', negatable: false)
              ..addOption('table')
              ..addOption('module'))
            .parse(args);
    if (r.rest.isEmpty) {
      throw CliException(
        'Usage: dartcore make:controller <Name> [--resource --table=users]',
        exitCode: 64,
      );
    }
    var cls = Names.pascal(Names.validated(r.rest.first, 'controller name'));
    if (!cls.endsWith('Controller')) cls = '${cls}Controller';
    final root = _projectRoot();
    final dir = _Layout(
      _setting(root, 'architecture', 'mvc'),
    ).dir('controller', module: r['module'] as String?);
    final file = _newFile('$dir/${Names.snake(cls)}.dart');
    if (r['resource'] as bool) {
      final base = cls.substring(0, cls.length - 'Controller'.length);
      final table = Names.validated(
        (r['table'] as String?) ?? Names.plural(Names.snake(base)),
        'table name',
      );
      file.writeAsStringSync(
        _resourceController(cls, table, const {
          'name': 'string',
        }, withPassword: false),
      );
      _out.writeln(
        'Created ${p.relative(file.path, from: _cwd.path)}  (edit the validation rules to match your columns)',
      );
    } else {
      file.writeAsStringSync(render(controllerStubT, {'class': cls}));
      _out.writeln('Created ${p.relative(file.path, from: _cwd.path)}');
    }
    _out.writeln('Register its routes in lib/routes/api.dart.');
    return 0;
  }

  int _makeModel(List<String> args) {
    final r =
        (ArgParser()
              ..addFlag('migration', abbr: 'm', negatable: false)
              ..addFlag('soft-deletes', negatable: false)
              ..addOption('fields', defaultsTo: 'name:string')
              ..addOption('module'))
            .parse(args);
    if (r.rest.isEmpty) {
      throw CliException(
        'Usage: dartcore make:model <Name> [-m] [--fields=name:string,age:int]',
        exitCode: 64,
      );
    }
    final cls = Names.pascal(Names.validated(r.rest.first, 'model name'));
    final table = Names.plural(Names.snake(cls));
    final fields = <String, String>{};
    for (final f in (r['fields'] as String).split(',')) {
      final parts = f.split(':');
      final fname = Names.validated(parts[0].trim(), 'field name');
      final type = parts.length > 1 ? parts[1].trim() : 'string';
      if (!const {
        'string',
        'int',
        'bool',
        'double',
        'datetime',
      }.contains(type)) {
        throw CliException(
          'Unknown field type "$type" (use string, int, bool, double, datetime).',
          exitCode: 64,
        );
      }
      fields[Names.snake(fname)] = type;
    }
    final root = _projectRoot();
    final arch = _setting(root, 'architecture', 'mvc');
    final dir = _Layout(arch).dir('model', module: r['module'] as String?);
    final file = _newFile('$dir/${Names.snake(cls)}.dart');

    String dartType(String t) => switch (t) {
      'int' => 'int',
      'bool' => 'bool',
      'double' => 'double',
      'datetime' => 'DateTime',
      _ => 'String',
    };
    String cast(String name, String t) => switch (t) {
      'int' => 'Casts.asInt(m[\'$name\'])',
      'bool' => 'Casts.asBool(m[\'$name\']) ?? false',
      'double' => 'Casts.asDouble(m[\'$name\'])',
      'datetime' => 'Casts.asDate(m[\'$name\'])',
      _ => 'm[\'$name\'] as String?',
    };
    String camel(String s) {
      final pc = Names.pascal(s);
      return pc[0].toLowerCase() + pc.substring(1);
    }

    final fieldLines = StringBuffer('  int? id;\n');
    final toMap = StringBuffer("        'id': id,\n");
    final fromMap = StringBuffer(
      "    if (m.containsKey('id')) id = Casts.asInt(m['id']);\n",
    );
    for (final e in fields.entries) {
      final isBool = e.value == 'bool';
      fieldLines.writeln(
        isBool
            ? '  bool ${camel(e.key)} = false;'
            : '  ${dartType(e.value)}? ${camel(e.key)};',
      );
      toMap.writeln("        '${e.key}': ${camel(e.key)},");
      fromMap.writeln(
        "    if (m.containsKey('${e.key}')) ${camel(e.key)} = ${cast(e.key, e.value)};",
      );
    }
    file.writeAsStringSync(
      render(modelT, {
        'class': cls,
        'table': table,
        'fields': fieldLines.toString(),
        'fillable': fields.keys.map((k) => "'$k'").join(', '),
        'toMap': toMap.toString(),
        'fromMap': fromMap.toString(),
        'softDeletes': (r['soft-deletes'] as bool)
            ? '\n  @override\n  bool get softDeletes => true;\n'
            : '',
      }),
    );
    _out.writeln('Created ${p.relative(file.path, from: _cwd.path)}');
    if (r['migration'] as bool) {
      final cols = StringBuffer();
      for (final e in fields.entries) {
        final m = switch (e.value) {
          'int' => 'integer',
          'bool' => 'boolean',
          'double' => 'double_',
          'datetime' => 'timestamp',
          _ => 'string',
        };
        cols.writeln(
          "        table.$m('${e.key}')${e.value == 'datetime' ? '.nullable()' : (e.value == 'bool' ? '.defaultValue(false)' : '')};",
        );
      }
      _writeMigration(
        root,
        'create_${table}_table',
        table,
        columns: cols.toString(),
        softDeletes: r['soft-deletes'] as bool,
      );
    }
    return 0;
  }

  int _makeMigration(List<String> args) {
    if (args.isEmpty) {
      throw CliException(
        'Usage: dartcore make:migration <name>  (e.g. create_users_table)',
        exitCode: 64,
      );
    }
    final name = Names.snake(Names.validated(args.first, 'migration name'));
    final m = RegExp(r'^create_(.+)_table$').firstMatch(name);
    final alter = RegExp(
      r'^(?:add|drop|alter|update)_.+?_(?:to|from|in|on)_(.+?)(?:_table)?$',
    ).firstMatch(name);
    _writeMigration(
      _projectRoot(),
      name,
      m?.group(1) ?? alter?.group(1) ?? 'table_name',
      create: m != null,
    );
    return 0;
  }

  void _writeMigration(
    Directory root,
    String name,
    String table, {
    bool? create,
    String columns = '',
    bool softDeletes = false,
  }) {
    final id = _migrationId(name);
    final isCreate = create ?? true;
    final file = _newFile('database/migrations/$id.dart');
    var body = render(isCreate ? migrationCreateT : migrationBlankT, {
      'class': Names.pascal(name),
      'id': id,
      'table': table,
      'columns': columns.isEmpty && isCreate
          ? "        // table.string('name');\n"
          : columns,
    });
    if (softDeletes) {
      body = body.replaceFirst(
        'table.timestamps();',
        'table.timestamps();\n        table.softDeletes();',
      );
    }
    file.writeAsStringSync(body);
    _registerInIndex(
      File(p.join(root.path, 'database/migrations/index.dart')),
      "import '$id.dart';",
      '${Names.pascal(name)}(),',
    );
    _out.writeln(
      'Created ${p.relative(file.path, from: _cwd.path)} and registered it in database/migrations/index.dart',
    );
  }

  int _makeSeeder(List<String> args) {
    final r = (ArgParser()..addOption('table')).parse(args);
    if (r.rest.isEmpty) {
      throw CliException(
        'Usage: dartcore make:seeder <Name> [--table=users]',
        exitCode: 64,
      );
    }
    var cls = Names.pascal(Names.validated(r.rest.first, 'seeder name'));
    if (!cls.endsWith('Seeder')) cls = '${cls}Seeder';
    final root = _projectRoot();
    final base = cls.substring(0, cls.length - 6);
    final table = Names.validated(
      (r['table'] as String?) ?? Names.plural(Names.snake(base)),
      'table name',
    );
    final fileName = '${Names.snake(cls)}.dart';
    final file = _newFile('database/seeders/$fileName');
    file.writeAsStringSync(
      render(seederT, {
        'class': cls,
        'table': table,
        'rows': "      // {'name': 'Example'},\n",
      }),
    );
    _registerInIndex(
      File(p.join(root.path, 'database/seeders/index.dart')),
      "import '$fileName';",
      '$cls(),',
    );
    _out.writeln(
      'Created ${p.relative(file.path, from: _cwd.path)} and registered it.',
    );
    return 0;
  }

  String _migrationId(String name) {
    final n = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}_${two(n.month)}_${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}_$name';
  }

  void _registerInIndex(File index, String importLine, String entry) {
    var text = index.readAsStringSync();
    text = text.replaceFirst(
      '// dartcore:imports',
      '$importLine\n// dartcore:imports',
    );
    text = text.replaceFirst(
      '  // dartcore:entries',
      '  $entry\n  // dartcore:entries',
    );
    index.writeAsStringSync(text);
  }
}
