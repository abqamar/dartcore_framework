/// File templates. Placeholders look like `{{name}}`; see [render].
library;

String render(String template, Map<String, String> vars) =>
    template.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (m) {
      final k = m[1]!;
      if (!vars.containsKey(k)) {
        throw StateError('Template variable "$k" not provided.');
      }
      return vars[k]!;
    });

const gitignoreT = r'''
.dart_tool/
build/
pubspec.lock
.env
*.sqlite
*.sqlite-wal
*.sqlite-shm
storage/logs/
''';

const envExampleT = r'''
APP_NAME={{name}}
APP_ENV=development
APP_HOST=127.0.0.1
APP_PORT=8080
APP_DEBUG=true

DB_DRIVER={{driver}}
DB_HOST=localhost
DB_PORT={{port}}
DB_DATABASE={{database}}
DB_USERNAME={{username}}
DB_PASSWORD=
DB_SSL={{ssl}}

# Generate with: openssl rand -base64 48   (must be at least 32 bytes)
JWT_SECRET=
''';

const envT = r'''
APP_NAME={{name}}
APP_ENV=development
APP_HOST=127.0.0.1
APP_PORT=8080
APP_DEBUG=true

DB_DRIVER={{driver}}
DB_HOST=localhost
DB_PORT={{port}}
DB_DATABASE={{database}}
DB_USERNAME={{username}}
DB_PASSWORD={{password}}
DB_SSL={{ssl}}

JWT_SECRET={{jwtSecret}}
''';

const pubspecT = r'''
name: {{package}}
description: A DartCore backend API.
publish_to: none
environment:
  sdk: ^3.10.0
dependencies:
{{dependencies}}
dev_dependencies:
  lints: ^6.0.0
  test: ^1.25.0
''';

const analysisT = r'''
include: package:lints/recommended.yaml
''';

const dartcoreYamlT = r'''
# DartCore project settings (read by `dartcore make:*`).
architecture: {{architecture}}
database: {{driver}}
auth: {{auth}}
''';

const readmeT = r'''
# {{name}}

A backend API built with [DartCore](https://github.com/).

## Run it

```bash
dart pub get
dartcore migrate        # create tables
dartcore db:seed        # optional sample data
dartcore serve          # http://127.0.0.1:8080
```

Try it:

```bash
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/api/users
```

## Useful commands

| Command | What it does |
|---|---|
| `dartcore serve --port 3000` | start the server |
| `dartcore route:list` | list registered routes |
| `dartcore make:controller Name` | generate a controller |
| `dartcore make:model Name -m` | generate a model (and migration) |
| `dartcore make:migration create_x_table` | generate a migration |
| `dartcore migrate:status` | show migration state |

Configuration lives in `.env` (never commit it; `.env.example` documents the keys).
{{databaseNote}}
''';

const serverT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:{{package}}/config/database.dart';
import 'package:{{package}}/routes/api.dart';
{{authImport}}
Future<void> main() async {
  await Config.load();
  await connectDatabase();
{{authBoot}}
  final app = DartCore();
  app.use(const SecurityHeadersMiddleware());
  app.use(RateLimitMiddleware(maxRequests: 300, duration: const Duration(minutes: 1)));

  registerRoutes(app);
  await app.start();
}
''';

const consoleT = r'''
import 'dart:io';

import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_migrations/dartcore_migrations.dart';
import 'package:{{package}}/config/database.dart';
import 'package:{{package}}/routes/api.dart';

import '../database/migrations/index.dart';
import '../database/seeders/index.dart';

/// Entry point used by the `dartcore` CLI (migrate, db:seed, route:list, ...).
Future<void> main(List<String> args) async {
  await Config.load();

  if (args.isNotEmpty && args.first == 'route:list') {
    final app = DartCore(database: DatabaseManager());
    registerRoutes(app);
    for (final r in app.routes) {
      stdout.writeln('${r.method.padRight(7)} ${r.path}${r.name != null ? '  (${r.name})' : ''}');
    }
    return;
  }

  if (args.isNotEmpty && args.first == 'doctor') {
    // Used by `dartcore doctor`: checks the database with this project's adapter.
    exitCode = await MigrationConsole.doctor(
      connect: connectDatabase,
      database: DB.connection,
      migrations: migrations,
    );
    try {
      await DB.disconnect();
    } catch (_) {}
    return;
  }

  await connectDatabase();
  final console = MigrationConsole(
    database: DB.connection(),
    migrations: migrations,
    seeders: seeders,
    environment: Config.environment,
  );
  exitCode = await console.run(args);
  await DB.disconnect();
}
''';

const databaseConfigT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_{{driverPkg}}/dartcore_{{driverPkg}}.dart';

/// Registers the {{driverLabel}} adapter and connects using the `DB_*` keys
/// from `.env`.
Future<void> connectDatabase() async {
  {{registerFn}}();
  await DB.connectWith(ConnectionConfig.fromConfig(Config.instance));
}
''';

const migrationsIndexT = r'''
import 'package:dartcore_migrations/dartcore_migrations.dart';
// dartcore:imports

/// All migrations, in any order (they run sorted by id). `dartcore make:migration`
/// appends here automatically.
final List<Migration> migrations = <Migration>[
  // dartcore:entries
];
''';

const seedersIndexT = r'''
import 'package:dartcore_migrations/dartcore_migrations.dart';
// dartcore:imports

/// Seeders run by `dartcore db:seed`, in order.
final List<Seeder> seeders = <Seeder>[
  // dartcore:entries
];
''';

const migrationCreateT = r'''
// ignore_for_file: file_names
import 'package:dartcore_migrations/dartcore_migrations.dart';

class {{class}} extends Migration {
  @override
  String get id => '{{id}}';

  @override
  Future<void> up(SchemaBuilder schema) => Schema.create('{{table}}', (table) {
        table.id();
{{columns}}        table.timestamps();
      });

  @override
  Future<void> down(SchemaBuilder schema) => Schema.dropIfExists('{{table}}');
}
''';

const migrationBlankT = r'''
// ignore_for_file: file_names
import 'package:dartcore_migrations/dartcore_migrations.dart';

class {{class}} extends Migration {
  @override
  String get id => '{{id}}';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await Schema.table('{{table}}', (table) {
      // table.string('new_column').nullable();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await Schema.table('{{table}}', (table) {
      // table.dropColumn('new_column');
    });
  }
}
''';

const seederT = r'''
import 'package:dartcore_migrations/dartcore_migrations.dart';

class {{class}} extends Seeder {
  @override
  Future<void> run() async {
    await db.table('{{table}}').insertMany([
{{rows}}    ]);
  }
}
''';

const controllerStubT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';

class {{class}} {
  Future<Response> index(Request request) async {
    return Response.success(<Object>[], message: '{{class}} index');
  }
}
''';

const controllerResourceT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';

/// CRUD controller for the `{{table}}` table.
class {{class}} {
  static const _sortable = [{{sortable}}];

  /// Columns returned to clients. Listing them explicitly (instead of `*`)
  /// means a sensitive column added later is never exposed by accident.
  static const _columns = [{{columns}}];

  Future<Response> index(Request request) async {
    final page = int.tryParse(request.query('page') ?? '') ?? 1;
    final limit = (int.tryParse(request.query('limit') ?? '') ?? 20).clamp(1, 100);
    final result = await DB
        .table('{{table}}')
        .select(_columns)
        .orderByAllowed(request.query('sort'), _sortable, fallback: 'id')
        .paginate(page: page < 1 ? 1 : page, limit: limit);
    return Response.success(result.data, message: '{{label}} retrieved successfully', meta: result.meta);
  }

  Future<Response> show(Request request) async {
    final row = await DB.table('{{table}}').select(_columns).find(request.param('id')!);
    if (row == null) return Response.notFound('{{singular}} not found');
    return Response.success(row);
  }

  Future<Response> store(Request request) async {
    final v = Validate.request(await request.json(), {
{{rules}}    });
    if (v.fails) return Response.validationError(v.errors);
    final now = DateTime.now().toUtc();
    final created = await DB.table('{{table}}').insert({...v.validated, 'created_at': now, 'updated_at': now});
    final row = await DB.table('{{table}}').select(_columns).find(created['id']!);
    return Response.success(row, message: '{{singular}} created', status: 201);
  }

  Future<Response> update(Request request) async {
    final id = request.param('id')!;
    final v = Validate.request(await request.json(), {
{{updateRules}}    });
    if (v.fails) return Response.validationError(v.errors);
    if (v.validated.isEmpty) return Response.badRequest('Nothing to update');
    final affected = await DB
        .table('{{table}}')
        .where('id', id)
        .update({...v.validated, 'updated_at': DateTime.now().toUtc()});
    if (affected == 0) return Response.notFound('{{singular}} not found');
    return Response.success(await DB.table('{{table}}').select(_columns).find(id), message: '{{singular}} updated');
  }

  Future<Response> destroy(Request request) async {
    final affected = await DB.table('{{table}}').where('id', request.param('id')!).delete();
    if (affected == 0) return Response.notFound('{{singular}} not found');
    return Response.noContent();
  }
}
''';

const routesMvcT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';
{{imports}}
/// Registers every route. Called by `bin/server.dart` and `dartcore route:list`.
void registerRoutes(DartCore app) {
  app.get('/health', (request) => Response.success({'status': 'ok'}), name: 'health');

  app.group('/api', {{groupMiddleware}}routes: () {
    final users = UserController();
    app.get('/users', users.index, name: 'users.index');
    app.get('/users/:id', users.show, name: 'users.show');
{{writeRoutes}}  });
{{authRoutes}}}
''';

const middlewareT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';

/// Runs around every request it is attached to. Call `next(request)` to
/// continue, or return a response to stop here.
class {{class}} extends Middleware {
  const {{class}}();

  @override
  Future<Response> handle(Request request, Handler next) async {
    // before the handler
    final response = await next(request);
    // after the handler
    return response;
  }
}
''';

const serviceT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';

/// Business logic lives here, away from HTTP concerns.
class {{class}} {
  {{class}}([DatabaseOperations? db]) : _db = db;
  final DatabaseOperations? _db;

  DatabaseOperations get db => _db ?? DB.manager;
}
''';

const resourceT = r'''
/// Shapes a record for API output (hide internals, rename fields, format values).
class {{class}} {
  {{class}}(this.data);
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'id': data['id'],
        // add the fields you want to expose
      };

  static List<Map<String, Object?>> collection(Iterable<Map<String, Object?>> rows) =>
      [for (final r in rows) {{class}}(r).toJson()];
}
''';

const validatorT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';

/// Validation rules for {{class}}.
class {{class}} {
  static const Map<String, Object> rules = {
    // 'name': 'required|string|min:3',
  };

  static ValidationResult validate(Map<String, dynamic> data) =>
      Validate.request(data, rules);
}
''';

const modelT = r'''
import 'package:dartcore_orm/dartcore_orm.dart';

class {{class}} extends Model {
{{fields}}
  @override
  String get table => '{{table}}';
{{softDeletes}}
  /// Attributes that may be set from request data. Everything else is ignored
  /// by `fill()` / `create()` / `update()`.
  @override
  List<String> get fillable => [{{fillable}}];

  @override
  Map<String, Object?> toMap() => {
{{toMap}}      };

  @override
  void fillFromMap(Map<String, Object?> m) {
{{fromMap}}  }

  static final repo = ModelRepository<{{class}}>({{class}}.new);
  static ModelQuery<{{class}}> query() => repo.query();
  static Future<{{class}}?> find(Object id) => repo.find(id);
  static Future<List<{{class}}>> all() => repo.all();
  static Future<{{class}}> create(Map<String, Object?> attributes) => repo.create(attributes);
}
''';

const authT = r'''
import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_auth/dartcore_auth.dart';

/// Maps rows of the `users` table to [AuthUser]s.
class DbUserRepository implements UserRepository {
  @override
  Future<AuthUser?> findById(String id) async {
    final row = await DB.table('users').find(id);
    if (row == null) return null;
    return AuthUser(id: row['id']!, email: row['email'] as String?, roles: const ['user']);
  }
}

late AuthService auth;

/// Call once at startup, after the database is connected.
Future<void> configureAuth() async {
  await DatabaseAuthStores.createTables(DB.manager);
  auth = AuthService(
    secret: Config.require('JWT_SECRET'),
    users: DbUserRepository(),
    stores: DatabaseAuthStores(DB.manager).stores,
  );
  Auth.configure(auth);
}

void registerAuthRoutes(DartCore app) {
  app.group('/auth', routes: () {
    app.post('/register', (request) async {
      final v = Validate.request(await request.json(), {
        'name': 'required|string|min:2|max:100',
        'email': 'required|email',
        'password': 'required|string|min:8|max:200',
      });
      if (v.fails) return Response.validationError(v.errors);
      final taken = await DB.table('users').where('email', v.get<String>('email')!.toLowerCase()).exists();
      if (taken) {
        return Response.validationError({'email': ['The email has already been taken.']});
      }
      final user = await DB.table('users').insert({
        'name': v.get<String>('name'),
        'email': v.get<String>('email')!.toLowerCase(),
        'password': await auth.hashPassword(v.get<String>('password')!),
      });
      final tokens = await auth.createTokens(AuthUser(id: user['id']!, email: user['email'] as String?, roles: const ['user']));
      return Response.success(tokens.toJson(), message: 'Registered', status: 201);
    });

    app.post('/login', (request) async {
      final v = Validate.request(await request.json(), {'email': 'required|email', 'password': 'required|string'});
      if (v.fails) return Response.validationError(v.errors);
      final row = await DB.table('users').where('email', v.get<String>('email')!.toLowerCase()).first();
      // Same message for unknown email and wrong password (no user enumeration).
      final ok = row != null && await auth.checkPassword(v.get<String>('password')!, row['password'] as String);
      if (!ok) return Response.unauthorized('Invalid credentials');
      final tokens = await auth.createTokens(AuthUser(id: row['id']!, email: row['email'] as String?, roles: const ['user']));
      return Response.success(tokens.toJson(), message: 'Logged in');
    }, middleware: [RateLimitMiddleware(maxRequests: 10, duration: const Duration(minutes: 1))]);

    app.post('/refresh', (request) async {
      final body = await request.json();
      final token = body['refresh_token'];
      if (token is! String) {
        return Response.badRequest('refresh_token is required');
      }
      return Response.success((await auth.refresh(token)).toJson());
    });

    app.get('/me', (request) async {
      final user = await Auth.user(request);
      return Response.success({'id': user!.id, 'email': user.email, 'roles': user.roles});
    }, middleware: [Auth.middleware()]);

    app.post('/logout', (request) async {
      final body = await request.json().catchError((_) => <String, dynamic>{});
      await Auth.logout(request, refreshToken: body['refresh_token'] as String?);
      return Response.success(null, message: 'Logged out');
    }, middleware: [Auth.middleware()]);
  });
}
''';
