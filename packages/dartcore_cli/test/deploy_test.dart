import 'dart:io';

import 'package:dartcore_cli/dartcore_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Records every process the CLI would start and fakes the compiler.
class FakeProcesses {
  final calls = <List<String>>[];
  bool crossCompile = true;
  String? compileFailure;

  Future<int> start(
    String exe,
    List<String> args,
    String dir,
    Map<String, String> env,
  ) async {
    calls.add([exe, ...args]);
    return 0;
  }

  Future<ProcessResult> capture(
    String exe,
    List<String> args,
    String dir,
  ) async {
    calls.add([exe, ...args]);
    if (args.contains('--help')) {
      return ProcessResult(
        0,
        0,
        crossCompile ? '    --target-os   Compile to a specific OS.' : 'usage',
        '',
      );
    }
    if (args.length > 1 && args[0] == 'compile') {
      if (compileFailure != null) {
        return ProcessResult(0, 1, '', compileFailure);
      }
      final out = args[args.indexOf('-o') + 1];
      File(out).writeAsBytesSync(List.filled(2048, 1));
    }
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  late Directory tmp;
  late StringBuffer out, err;
  late FakeProcesses fake;
  late DartCoreCli cli;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dc_deploy');
    out = StringBuffer();
    err = StringBuffer();
    fake = FakeProcesses();
    cli = DartCoreCli(
      out: out,
      err: err,
      cwd: tmp,
      interactive: false,
      starter: fake.start,
      capture: fake.capture,
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String read(String path) => File(p.join(tmp.path, path)).readAsStringSync();
  bool exists(String path) =>
      FileSystemEntity.typeSync(p.join(tmp.path, path)) !=
      FileSystemEntityType.notFound;

  /// A minimal project directory (no DartCore packages needed).
  void project({
    String database = 'postgres',
    String? env,
    String pubspecDeps = '  dartcore_postgres: ^0.1.0',
    bool auth = false,
    bool examplEnv = true,
  }) {
    File(p.join(tmp.path, 'dartcore.yaml')).writeAsStringSync(
      'architecture: mvc\ndatabase: $database\nauth: $auth\n',
    );
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: my_api\ndependencies:\n$pubspecDeps\n\ndev_dependencies:\n  test: any\n',
    );
    if (examplEnv) {
      File(
        p.join(tmp.path, '.env.example'),
      ).writeAsStringSync('APP_PORT=9090\nJWT_SECRET=\nDB_PASSWORD=\n');
    }
    if (env != null) File(p.join(tmp.path, '.env')).writeAsStringSync(env);
  }

  group('deploy:init', () {
    test('writes the unit, nginx site, install script and README', () async {
      project();
      expect(
        await cli.run([
          'deploy:init',
          '--name',
          'my_api',
          '--domain',
          'api.example.com',
          '--user',
          'svc_api',
          '--port',
          '9000',
        ]),
        0,
        reason: '$err',
      );
      final unit = read('deploy/my_api.service');
      expect(unit, contains('User=svc_api'));
      expect(unit, contains('Group=svc_api'));
      expect(unit, contains('WorkingDirectory=/opt/my_api'));
      expect(unit, contains('ExecStart=/opt/my_api/server'));
      expect(unit, contains('Restart=on-failure'));
      expect(unit, contains('NoNewPrivileges=true'));
      expect(unit, contains('ProtectSystem=full'));
      expect(unit, contains('ReadWritePaths=/opt/my_api/storage'));

      final nginx = read('deploy/nginx.conf');
      expect(nginx, contains('server_name api.example.com;'));
      expect(nginx, contains('proxy_pass http://127.0.0.1:9000;'));
      expect(
        nginx,
        contains(
          r'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
        ),
      );
      expect(nginx, contains(r'proxy_set_header X-Forwarded-Proto $scheme;'));
      expect(nginx, contains('client_max_body_size'));

      final readme = read('deploy/README.md');
      expect(
        readme,
        contains('rsync -av build/release/ user@host:~/my_api-release/'),
      );
      expect(
        readme,
        contains(
          "ssh -t user@host 'cd ~/my_api-release && sudo ./deploy/install.sh --migrate --nginx'",
        ),
      );
      expect(readme, contains('server.prev'));
      expect(readme, contains('Rolling back'));

      if (!Platform.isWindows) {
        expect(
          File(p.join(tmp.path, 'deploy/install.sh')).statSync().mode & 0x40,
          isNot(0),
          reason: 'install.sh must be executable',
        );
      }
    });

    test(
      'defaults: name from pubspec, port from .env.example, no domain',
      () async {
        project();
        expect(await cli.run(['deploy:init']), 0, reason: '$err');
        expect(exists('deploy/my_api.service'), isTrue);
        expect(read('deploy/my_api.service'), contains('User=my_api'));
        expect(read('deploy/nginx.conf'), contains('server_name _;'));
        expect(read('deploy/nginx.conf'), contains('127.0.0.1:9090'));
      },
    );

    test('install.sh contains the safety logic', () async {
      project();
      await cli.run(['deploy:init', '--name', 'my_api']);
      final sh = read('deploy/install.sh');
      expect(sh, startsWith('#!/usr/bin/env bash'));
      expect(sh, contains('set -euo pipefail'));
      expect(sh, contains('umask 077'));
      // never overwrite an existing .env
      expect(sh, contains('if [ -e "\${ENV_FILE}" ]; then'));
      expect(sh, contains('never overwritten'));
      // secret generation
      expect(sh, contains('openssl rand -base64 48'));
      expect(sh, contains('JWT_SECRET'));
      expect(sh, contains('_SECRET|_KEY'));
      // stops until the admin fills DB values
      expect(sh, contains('DB_PASSWORD'));
      expect(sh, contains('STOP:'));
      expect(sh, contains('exit 3'));
      // .env permissions
      expect(sh, contains('chmod 600 "\${ENV_FILE}"'));
      expect(
        sh,
        contains('chown "\${SERVICE_USER}:\${SERVICE_USER}" "\${ENV_FILE}"'),
      );
      // migrate only when asked
      expect(sh, contains('--migrate)'));
      expect(sh, contains('if [ "\${RUN_MIGRATE}" -eq 1 ]'));
      expect(
        sh,
        contains('runuser -u "\${SERVICE_USER}" -- ./console migrate'),
      );
      // service + nginx + health
      expect(sh, contains('systemctl enable'));
      expect(sh, contains('nginx -t'));
      expect(sh, contains('/health'));
      expect(sh, contains('TOTAL=9'));
      // never a recursive delete
      expect(sh, isNot(contains('rm -rf')));
      // all template variables were substituted
      expect(sh, isNot(contains('{{')));
      expect(read('deploy/my_api.service'), isNot(contains('{{')));
      expect(read('deploy/nginx.conf'), isNot(contains('{{')));
      expect(read('deploy/README.md'), isNot(contains('{{')));
    });

    test('install.sh passes bash -n', () async {
      if (Platform.isWindows) return;
      project();
      await cli.run(['deploy:init', '--name', 'my_api']);
      final r = Process.runSync('bash', [
        '-n',
        p.join(tmp.path, 'deploy/install.sh'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('does not overwrite without --force', () async {
      project();
      await cli.run(['deploy:init', '--name', 'my_api']);
      File(p.join(tmp.path, 'deploy/nginx.conf')).writeAsStringSync('mine');
      expect(await cli.run(['deploy:init', '--name', 'my_api']), 0);
      expect(read('deploy/nginx.conf'), 'mine');
      expect(out.toString(), contains('already exists'));
      expect(await cli.run(['deploy:init', '--name', 'my_api', '--force']), 0);
      expect(read('deploy/nginx.conf'), contains('proxy_pass'));
    });

    test('rejects values that could inject into the generated files', () async {
      project();
      for (final args in [
        ['--name', 'a;rm -rf /'],
        ['--name', 'Upper'],
        ['--name', 'my_api', '--user', r'x$(id)'],
        ['--name', 'my_api', '--domain', 'a.com; evil'],
        ['--name', 'my_api', '--domain', 'a b.com'],
        ['--name', 'my_api', '--port', '0'],
        ['--name', 'my_api', '--port', '99999'],
        ['--name', 'my_api', '--port', 'abc'],
      ]) {
        expect(await cli.run(['deploy:init', ...args]), 64, reason: '$args');
      }
      expect(exists('deploy'), isFalse);
    });

    test('requires a project', () async {
      expect(await cli.run(['deploy:init']), 1);
      expect(err.toString(), contains('Not inside a DartCore project'));
    });
  });

  group('build', () {
    test(
      'default target is linux-x64 and the bundle layout is complete',
      () async {
        project();
        expect(await cli.run(['build']), 0, reason: '$err');
        final compiles = fake.calls
            .where(
              (c) =>
                  c.length > 1 &&
                  c[1] == 'compile' &&
                  c[2] == 'exe' &&
                  !c.contains('--help'),
            )
            .toList();
        expect(compiles, hasLength(2));
        for (final c in compiles) {
          expect(
            c,
            containsAllInOrder([
              '--target-os',
              'linux',
              '--target-arch',
              'x64',
            ]),
          );
        }
        expect(fake.calls.first, ['dart', 'compile', 'exe', '--help']);
        expect(fake.calls, contains(equals(['dart', 'pub', 'get'])));
        for (final f in [
          'build/release/server',
          'build/release/console',
          'build/release/.env.example',
          'build/release/deploy/my_api.service',
          'build/release/deploy/nginx.conf',
          'build/release/deploy/install.sh',
          'build/release/deploy/README.md',
        ]) {
          expect(exists(f), isTrue, reason: f);
        }
        expect(
          exists('deploy/install.sh'),
          isTrue,
          reason: 'generated when missing',
        );
        expect(out.toString(), contains('2 KB'));
        expect(
          out.toString(),
          contains('rsync -av build/release/ user@host:~/my_api-release/'),
        );
        expect(
          out.toString(),
          contains('sudo ./deploy/install.sh --migrate --nginx'),
        );
        expect(
          exists('build/release/.env'),
          isFalse,
          reason: 'secrets are never bundled',
        );
      },
    );

    test('--target linux-arm64, --output and --no-console', () async {
      project();
      expect(
        await cli.run([
          'build',
          '--target',
          'linux-arm64',
          '-o',
          'out/rel',
          '--no-console',
        ]),
        0,
        reason: '$err',
      );
      final compiles = fake.calls
          .where(
            (c) => c.length > 1 && c[1] == 'compile' && !c.contains('--help'),
          )
          .toList();
      expect(compiles, hasLength(1));
      expect(compiles.single, containsAllInOrder(['--target-arch', 'arm64']));
      expect(exists('out/rel/server'), isTrue);
      expect(exists('out/rel/console'), isFalse);
    });

    test('--target host passes no cross-compile flags', () async {
      project();
      expect(await cli.run(['build', '--target', 'host']), 0, reason: '$err');
      expect(fake.calls.where((c) => c.contains('--target-os')), isEmpty);
      expect(fake.calls.any((c) => c.contains('--help')), isFalse);
    });

    test('unknown targets are rejected', () async {
      project();
      expect(await cli.run(['build', '--target', 'windows-x64']), 64);
      expect(fake.calls, isEmpty);
    });

    test('an SDK without cross-compilation gets a clear error', () async {
      project();
      fake.crossCompile = false;
      expect(await cli.run(['build']), 1);
      expect(err.toString(), contains('cannot cross-compile'));
      expect(err.toString(), contains('--target host'));
    });

    test(
      'SQLite projects are refused with an explanation, not a stack trace',
      () async {
        project(database: 'sqlite');
        expect(await cli.run(['build']), 1);
        expect(err.toString(), contains('SQLite'));
        expect(err.toString(), contains('native build hook'));
        expect(err.toString(), isNot(contains('#0')));
        expect(fake.calls, isEmpty, reason: 'must fail before compiling');
      },
    );

    test(
      'a direct sqlite dependency is detected, framework-internal ones are not',
      () async {
        project(pubspecDeps: '  dartcore_postgres: ^0.1.0\n  sqlite3: ^2.0.0');
        expect(await cli.run(['build']), 1);
        expect(err.toString(), contains('SQLite'));
        // dependency_overrides name every package and must not count
        File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
          'name: my_api\ndependencies:\n  dartcore_postgres: ^0.1.0\ndev_dependencies:\n  test: any\n'
          'dependency_overrides:\n  dartcore_sqlite:\n    path: ../x\n',
        );
        err.clear();
        expect(await cli.run(['build']), 0, reason: '$err');
      },
    );

    test('a native-hook compile failure is explained', () async {
      project();
      fake.compileFailure = 'Error: build hook failed for package:sqlite3';
      expect(await cli.run(['build']), 1);
      expect(err.toString(), contains('native build hook'));
    });

    test('requires a project and .env.example', () async {
      expect(await cli.run(['build']), 1);
      project(examplEnv: false);
      err.clear();
      expect(await cli.run(['build']), 1);
      expect(err.toString(), contains('.env.example'));
    });

    test(
      'real cross-compile of a generated Postgres project (slow)',
      () async {
        final root = p.dirname(p.dirname(Directory.current.path));
        final real = DartCoreCli(
          out: out,
          err: err,
          cwd: tmp,
          interactive: false,
        );
        expect(
          await real.run([
            'create',
            'e2e_api',
            '-d',
            'postgres',
            '--path',
            root,
          ]),
          0,
          reason: '$err',
        );
        final proj = Directory(p.join(tmp.path, 'e2e_api'));
        final inProject = DartCoreCli(
          out: out,
          err: err,
          cwd: proj,
          interactive: false,
        );
        expect(
          await inProject.run(['deploy:init', '--domain', 'api.example.com']),
          0,
        );
        expect(await inProject.run(['build']), 0, reason: '$err');
        for (final f in ['server', 'console']) {
          final bin = File(p.join(proj.path, 'build/release', f));
          expect(bin.lengthSync(), greaterThan(1000000));
          expect(bin.readAsBytesSync().sublist(0, 4), [
            0x7f,
            0x45,
            0x4c,
            0x46,
          ], reason: 'ELF');
        }
      },
      skip: Platform.environment['DARTCORE_E2E_BUILD'] == '1'
          ? false
          : 'slow; set DARTCORE_E2E_BUILD=1 to run',
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('doctor', () {
    const secret = 'S3cretValueThatMustNeverBePrinted-0123456789abcdef';
    const goodEnv =
        '''
APP_ENV=development
DB_DRIVER=postgres
DB_HOST=localhost
DB_PORT=5432
DB_DATABASE=my_api
DB_USERNAME=app
DB_PASSWORD=$secret
JWT_SECRET=$secret
APP_PORT=0
''';

    Future<int> doctor() => cli.run(['doctor']);

    test('outside a project', () async {
      expect(await doctor(), 1);
      expect(out.toString(), contains('FAIL  Project'));
    });

    test('missing .env is a failure with a fix', () async {
      project();
      expect(await doctor(), 1);
      expect(out.toString(), contains('FAIL  .env: no .env file'));
      expect(out.toString(), contains('Fix: run: cp .env.example .env'));
    });

    test('.env as a directory is detected', () async {
      project();
      Directory(p.join(tmp.path, '.env')).createSync();
      expect(await doctor(), 1);
      expect(out.toString(), contains('FAIL  .env: .env is a directory'));
      expect(out.toString(), contains('rmdir .env'));
    });

    test('placeholder database values', () async {
      project(
        env:
            'DB_DRIVER=postgres\nDB_HOST=localhost\nDB_DATABASE=CHANGE_ME\nDB_USERNAME=\nDB_PASSWORD=CHANGE_ME\n'
            'JWT_SECRET=$secret\nAPP_PORT=0\n',
      );
      expect(await doctor(), 1);
      final o = out.toString();
      expect(o, contains('FAIL  Database settings: DB_DATABASE, DB_USERNAME'));
      expect(
        o,
        contains('FAIL  DB_PASSWORD: is still a CHANGE_ME placeholder'),
      );
      expect(o, contains('WARN  Database connection: skipped'));
    });

    test('short JWT_SECRET', () async {
      project(
        env: goodEnv.replaceFirst(RegExp('JWT_SECRET=.*'), 'JWT_SECRET=short'),
      );
      expect(await doctor(), 1);
      expect(
        out.toString(),
        contains('FAIL  JWT_SECRET: is only 5 bytes; at least 32 are required'),
      );
    });

    test(
      'missing JWT_SECRET: warning in development, failure with auth',
      () async {
        final noJwt = goodEnv.replaceFirst(RegExp('JWT_SECRET=.*\n'), '');
        project(env: noJwt);
        await doctor();
        expect(out.toString(), contains('WARN  JWT_SECRET'));
        out.clear();
        project(env: noJwt, auth: true);
        expect(await doctor(), 1);
        expect(out.toString(), contains('FAIL  JWT_SECRET'));
      },
    );

    test(
      'empty DB_PASSWORD: warning in development, failure in production',
      () async {
        project(
          env: goodEnv.replaceFirst('DB_PASSWORD=$secret', 'DB_PASSWORD='),
        );
        await doctor();
        expect(out.toString(), contains('WARN  DB_PASSWORD: is empty'));
        out.clear();
        project(
          env: goodEnv
              .replaceFirst('DB_PASSWORD=$secret', 'DB_PASSWORD=')
              .replaceFirst('APP_ENV=development', 'APP_ENV=production'),
        );
        expect(await doctor(), 1);
        expect(out.toString(), contains('FAIL  DB_PASSWORD: is empty'));
      },
    );

    test('production sanity warnings', () async {
      project(
        env:
            '${goodEnv.replaceFirst('APP_ENV=development', 'APP_ENV=production')}\nCORS_ORIGINS=*\nAPP_DEBUG=true\n',
      );
      await doctor();
      final o = out.toString();
      expect(o, contains('WARN  Production settings'));
      expect(o, contains('CORS_ORIGINS=* allows any website'));
      expect(o, contains('APP_DEBUG=true'));
      expect(o, contains('APP_TRUST_PROXY is not set'));
    });

    test('storage directory must be writable', () async {
      project(env: '${goodEnv}STORAGE_PATH=missing_dir\n');
      expect(await doctor(), 1);
      expect(out.toString(), contains('FAIL  Storage: directory'));
      out.clear();
      Directory(p.join(tmp.path, 'missing_dir')).createSync();
      await doctor();
      expect(out.toString(), contains('OK    Storage'));
    });

    test(
      'a healthy project passes (database check skipped without pub get)',
      () async {
        project(env: goodEnv);
        expect(await doctor(), 0, reason: out.toString());
        final o = out.toString();
        expect(o, contains('OK    .env: regular file'));
        expect(o, contains('OK    JWT_SECRET: set (50 bytes)'));
        expect(
          o,
          contains(
            'WARN  Database connection: skipped: dependencies are not installed',
          ),
        );
        expect(o, contains('0 failure(s)'));
      },
    );

    test('never prints secret values', () async {
      project(
        env: goodEnv.replaceFirst('APP_ENV=development', 'APP_ENV=production'),
      );
      await doctor();
      expect(out.toString(), isNot(contains(secret)));
      expect(err.toString(), isNot(contains(secret)));
    });

    test('runs the project console and relays its checks', () async {
      project(env: goodEnv);
      Directory(p.join(tmp.path, '.dart_tool')).createSync();
      File(
        p.join(tmp.path, '.dart_tool/package_config.json'),
      ).writeAsStringSync('{}');
      final doc = DartCoreCli(
        out: out,
        err: err,
        cwd: tmp,
        interactive: false,
        capture: (exe, args, dir) async {
          expect(args, ['run', 'bin/console.dart', 'doctor']);
          return ProcessResult(
            0,
            1,
            'Running build hooks...\n'
                'OK    Database connection: SELECT 1 succeeded (postgres://localhost:5432/my_api).\n'
                'WARN  Migrations: 0 applied, 2 pending.\n'
                '      Fix: run "dartcore migrate"\n',
            '',
          );
        },
      );
      expect(await doc.run(['doctor']), 0);
      expect(
        out.toString(),
        contains('OK    Database connection: SELECT 1 succeeded'),
      );
      expect(
        out.toString(),
        contains('WARN  Migrations: 0 applied, 2 pending.'),
      );
      expect(out.toString(), contains('Fix: run "dartcore migrate"'));
    });

    test('a failing database check makes doctor exit 1', () async {
      project(env: goodEnv);
      Directory(p.join(tmp.path, '.dart_tool')).createSync();
      File(
        p.join(tmp.path, '.dart_tool/package_config.json'),
      ).writeAsStringSync('{}');
      final doc = DartCoreCli(
        out: out,
        err: err,
        cwd: tmp,
        interactive: false,
        capture: (exe, args, dir) async => ProcessResult(
          0,
          1,
          'FAIL  Database connection: could not connect. refused\n      Fix: check DB_HOST\n',
          '',
        ),
      );
      expect(await doc.run(['doctor']), 1);
      expect(
        out.toString(),
        contains('FAIL  Database connection: could not connect. refused'),
      );
      expect(out.toString(), contains('Fix: check DB_HOST'));
    });

    test('a console that cannot run is reported, not hidden', () async {
      project(env: goodEnv);
      Directory(p.join(tmp.path, '.dart_tool')).createSync();
      File(
        p.join(tmp.path, '.dart_tool/package_config.json'),
      ).writeAsStringSync('{}');
      final doc = DartCoreCli(
        out: out,
        err: err,
        cwd: tmp,
        interactive: false,
        capture: (exe, args, dir) async =>
            ProcessResult(0, 255, '', 'Error: compile failed in console.dart'),
      );
      expect(await doc.run(['doctor']), 1);
      expect(out.toString(), contains('could not run bin/console.dart doctor'));
      expect(out.toString(), contains('compile failed'));
    });

    test('port check warns when the port is taken', () async {
      final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(s.close);
      project(env: goodEnv.replaceFirst('APP_PORT=0', 'APP_PORT=${s.port}'));
      expect(await doctor(), 0, reason: 'a taken port is a warning');
      expect(out.toString(), contains('WARN  Port: cannot bind ${s.port}'));
    });
  });
}
