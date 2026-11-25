import 'dart:io';

import 'package:dartcore_cli/dartcore_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StringBuffer out, err;
  late DartCoreCli cli;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dc_cli');
    out = StringBuffer();
    err = StringBuffer();
    cli = DartCoreCli(out: out, err: err, cwd: tmp, interactive: false);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String read(String path) => File(p.join(tmp.path, path)).readAsStringSync();
  bool exists(String path) => File(p.join(tmp.path, path)).existsSync();

  group('names', () {
    test('pascal/snake/plural', () {
      expect(Names.pascal('user_controller'), 'UserController');
      expect(Names.pascal('UserController'), 'UserController');
      expect(Names.snake('UserController'), 'user_controller');
      expect(Names.plural('category'), 'categories');
      expect(Names.plural('user'), 'users');
      expect(Names.plural('box'), 'boxes');
      expect(Names.plural('day'), 'days');
    });
    test('hostile names are rejected', () {
      for (final bad in [
        '../evil',
        'a/b',
        'a b',
        '',
        r'a;rm',
        '1abc',
        'x\ny',
      ]) {
        expect(
          () => Names.validated(bad, 'name'),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('--version and --help', () async {
    expect(await cli.run(['--version']), 0);
    expect(out.toString(), startsWith('dartcore '));
    expect(await cli.run(['--help']), 0);
    expect(out.toString(), contains('make:model'));
    expect(await cli.run(['frobnicate']), 64);
    expect(err.toString(), contains('Unknown command'));
  });

  group('create', () {
    for (final arch in ['simple', 'mvc', 'clean', 'modular']) {
      test('creates a complete $arch project', () async {
        expect(
          await cli.run([
            'create',
            'my_api',
            '-d',
            'sqlite',
            '-a',
            arch,
            '--no-pub-get',
          ]),
          0,
          reason: '$err',
        );
        for (final f in [
          'pubspec.yaml',
          '.env',
          '.env.example',
          '.gitignore',
          'README.md',
          'dartcore.yaml',
          'bin/server.dart',
          'bin/console.dart',
          'lib/config/database.dart',
          'lib/routes/api.dart',
          'database/migrations/index.dart',
          'database/seeders/index.dart',
        ]) {
          expect(exists('my_api/$f'), isTrue, reason: f);
        }
        expect(read('my_api/dartcore.yaml'), contains('architecture: $arch'));
        expect(
          read('my_api/lib/config/database.dart'),
          contains('registerSqlite'),
        );
        expect(
          Directory(
            p.join(tmp.path, 'my_api/database/migrations'),
          ).listSync().length,
          2,
        );
      });
    }

    test(
      '.env gets a unique random JWT secret and .env.example none',
      () async {
        await cli.run(['create', 'a', '-d', 'sqlite', '--no-pub-get']);
        await cli.run(['create', 'b', '-d', 'sqlite', '--no-pub-get']);
        String secret(String proj) => RegExp(
          r'JWT_SECRET=(\S+)',
        ).firstMatch(read('$proj/.env'))!.group(1)!;
        expect(secret('a').length, greaterThanOrEqualTo(48));
        expect(secret('a'), isNot(secret('b')));
        expect(read('a/.env.example'), contains('JWT_SECRET=\n'));
        expect(read('a/.gitignore'), contains('.env'));
      },
    );

    test(
      'database choice wires the right adapter and driver settings',
      () async {
        await cli.run(['create', 'pg', '-d', 'postgres', '--no-pub-get']);
        expect(
          read('pg/lib/config/database.dart'),
          contains('registerPostgres'),
        );
        expect(read('pg/.env'), contains('DB_DRIVER=postgres'));
        await cli.run(['create', 'my', '-d', 'mysql', '--no-pub-get']);
        expect(read('my/lib/config/database.dart'), contains('registerMySql'));
        await cli.run(['create', 'sb', '-d', 'supabase', '--no-pub-get']);
        expect(read('sb/.env'), contains('DB_SSL=require'));
        expect(
          read('sb/README.md'),
          contains('not'),
          reason: 'documents what Supabase support is missing',
        );
        expect(
          await cli.run(['create', 'ms', '-d', 'mssql', '--no-pub-get']),
          0,
          reason: '$err',
        );
        expect(read('ms/lib/config/database.dart'), contains('registerMssql'));
        expect(read('ms/pubspec.yaml'), contains('dartcore_mssql'));
        final env = read('ms/.env');
        expect(env, contains('DB_DRIVER=mssql'));
        expect(env, contains('DB_PORT=1433'));
        expect(env, contains('DB_USERNAME=sa'));
        expect(
          env,
          contains('DB_SSL=require'),
          reason: 'never default to an unencrypted SQL Server login',
        );
        expect(read('ms/README.md'), contains('experimental'));
      },
    );

    test('--auth adds auth routes and protects the users list', () async {
      await cli.run([
        'create',
        'sec',
        '-d',
        'sqlite',
        '--auth',
        '--no-pub-get',
      ]);
      expect(exists('sec/lib/auth/auth.dart'), isTrue);
      final routes = read('sec/lib/routes/api.dart');
      expect(routes, contains('Auth.middleware()'));
      expect(routes, isNot(contains('users.store')));
      expect(read('sec/bin/server.dart'), contains('configureAuth'));
      expect(
        read(
          'sec/database/migrations/${Directory(p.join(tmp.path, 'sec/database/migrations')).listSync().map((e) => p.basename(e.path)).firstWhere((n) => n.contains('create_users'))}',
        ),
        contains("table.string('password')"),
      );
    });

    test(
      'generated resource controller never selects * (no leaking columns)',
      () async {
        await cli.run([
          'create',
          'leak',
          '-d',
          'sqlite',
          '--auth',
          '--no-pub-get',
        ]);
        final c = read('leak/lib/controllers/user_controller.dart');
        expect(c, contains('.select(_columns)'));
        expect(c, isNot(contains("'password'")));
      },
    );

    test('refuses non-empty target, invalid names and unknown MSSQL', () async {
      await cli.run(['create', 'dup', '-d', 'sqlite', '--no-pub-get']);
      expect(
        await cli.run(['create', 'dup', '-d', 'sqlite', '--no-pub-get']),
        1,
      );
      expect(err.toString(), contains('already exists'));
      expect(await cli.run(['create', '../escape', '--no-pub-get']), 64);
      expect(
        Directory(p.join(tmp.parent.path, 'escape')).existsSync(),
        isFalse,
      );
    });
  });

  group('generators', () {
    setUp(() async {
      await cli.run([
        'create',
        'proj',
        '-d',
        'sqlite',
        '-a',
        'mvc',
        '--no-pub-get',
      ]);
      cli = DartCoreCli(
        out: out,
        err: err,
        cwd: Directory(p.join(tmp.path, 'proj', 'lib')),
        interactive: false,
      );
    });

    test('make:model with fields, migration and soft deletes', () async {
      expect(
        await cli.run([
          'make:model',
          'BlogPost',
          '-m',
          '--fields=title:string,views:int,published:bool',
          '--soft-deletes',
        ]),
        0,
        reason: '$err',
      );
      final m = read('proj/lib/models/blog_post.dart');
      expect(m, contains("String get table => 'blog_posts'"));
      expect(m, contains('bool published = false;'));
      expect(m, contains('bool get softDeletes => true'));
      expect(m, contains("fillable => ['title', 'views', 'published']"));
      final idx = read('proj/database/migrations/index.dart');
      expect(idx, contains('CreateBlogPostsTable()'));
      expect(idx, contains('create_blog_posts_table.dart'));
    });

    test(
      'make:controller / service / middleware / resource / validator / seeder',
      () async {
        expect(await cli.run(['make:controller', 'Order']), 0);
        expect(exists('proj/lib/controllers/order_controller.dart'), isTrue);
        expect(await cli.run(['make:controller', 'Invoice', '--resource']), 0);
        expect(
          read('proj/lib/controllers/invoice_controller.dart'),
          contains("DB\n        .table('invoices')"),
        );
        expect(await cli.run(['make:service', 'Billing']), 0);
        expect(exists('proj/lib/services/billing_service.dart'), isTrue);
        expect(await cli.run(['make:middleware', 'AuthMiddleware']), 0);
        expect(
          read('proj/lib/middleware/auth_middleware.dart'),
          contains('class AuthMiddleware extends Middleware'),
        );
        expect(await cli.run(['make:resource', 'User']), 0);
        expect(await cli.run(['make:validator', 'Login']), 0);
        expect(await cli.run(['make:seeder', 'Product']), 0);
        expect(
          read('proj/database/seeders/index.dart'),
          contains('ProductSeeder()'),
        );
      },
    );

    test(
      'make:migration picks create vs alter template and never overwrites',
      () async {
        expect(await cli.run(['make:migration', 'create_orders_table']), 0);
        expect(
          await cli.run(['make:migration', 'add_total_to_orders_table']),
          0,
        );
        final files = Directory(
          p.join(tmp.path, 'proj/database/migrations'),
        ).listSync().map((e) => p.basename(e.path)).toList();
        final create = files.firstWhere((f) => f.contains('create_orders'));
        final alter = files.firstWhere((f) => f.contains('add_total'));
        expect(
          read('proj/database/migrations/$create'),
          contains("Schema.create('orders'"),
        );
        expect(
          read('proj/database/migrations/$alter'),
          contains("Schema.table('orders'"),
        );
        expect(await cli.run(['make:controller', 'Order']), 0);
        expect(await cli.run(['make:controller', 'Order']), 1);
        expect(err.toString(), contains('not overwriting'));
      },
    );

    test('generators reject hostile names and unknown field types', () async {
      expect(await cli.run(['make:model', '../../evil']), 64);
      expect(await cli.run(['make:model', 'Ok', '--fields=a:blob']), 64);
      expect(exists('evil.dart'), isFalse);
    });

    test('commands outside a project explain what to do', () async {
      final lone = Directory.systemTemp.createTempSync('dc_lone');
      addTearDown(() => lone.deleteSync(recursive: true));
      final c = DartCoreCli(out: out, err: err, cwd: lone, interactive: false);
      expect(await c.run(['make:model', 'X']), 1);
      expect(err.toString(), contains('Not inside a DartCore project'));
    });
  });
}
