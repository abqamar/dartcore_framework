import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_auth/dartcore_auth.dart';

/// Reads users from the database for token authentication.
class UserRepo implements UserRepository {
  UserRepo(this.db);
  final DatabaseOperations db;

  @override
  Future<AuthUser?> findById(String id) async {
    final row = await db
        .table('users')
        .select(['id', 'email', 'role'])
        .find(id);
    if (row == null) return null;
    return AuthUser(
      id: row['id']!,
      email: row['email'] as String?,
      roles: [row['role'] as String],
      permissions: row['role'] == 'admin'
          ? const ['*']
          : const ['products.read'],
    );
  }
}

/// Builds the app around a database manager (so tests can use SQLite).
/// Call `DatabaseAuthStores.createTables` on [database] before serving.
DartCore buildApp(
  DatabaseManager database, {
  required String jwtSecret,
  Logger? logger,
}) {
  final db = database.defaultConnection;
  final auth = AuthService(
    secret: jwtSecret,
    users: UserRepo(db),
    stores: DatabaseAuthStores(db).stores,
  );
  // Settings come from APP_PORT, APP_ENV, ... (see Config).
  final app = DartCore(database: database, logger: logger);
  app.use(const SecurityHeadersMiddleware());

  app.get('/health', (r) => Response.success({'status': 'ok'}));

  // ---- authentication -----------------------------------------------------------
  app.group(
    '/auth',
    routes: () {
      app.post('/register', (request) async {
        final v = Validate.request(await request.json(), {
          'name': 'required|string|min:2|max:100',
          'email': 'required|email',
          'password': 'required|string|min:8|max:200',
        });
        if (v.fails) return Response.validationError(v.errors);
        final email = v.get<String>('email')!.toLowerCase();
        if (await db.table('users').where('email', email).exists()) {
          return Response.validationError({
            'email': ['The email has already been taken.'],
          });
        }
        final now = DateTime.now().toUtc();
        final user = await db.table('users').insert({
          'name': v.get<String>('name'),
          'email': email,
          'password': await auth.hashPassword(v.get<String>('password')!),
          'created_at': now,
          'updated_at': now,
        });
        final tokens = await auth.createTokens(
          (await UserRepo(db).findById('${user['id']}'))!,
        );
        return Response.success(
          tokens.toJson(),
          message: 'Registered',
          status: 201,
        );
      });

      app.post(
        '/login',
        (request) async {
          final v = Validate.request(await request.json(), {
            'email': 'required|email',
            'password': 'required|string',
          });
          if (v.fails) return Response.validationError(v.errors);
          final row = await db
              .table('users')
              .where('email', v.get<String>('email')!.toLowerCase())
              .first();
          final ok =
              row != null &&
              await auth.checkPassword(
                v.get<String>('password')!,
                row['password'] as String,
              );
          if (!ok) return Response.unauthorized('Invalid credentials');
          final user = await UserRepo(db).findById('${row['id']}');
          return Response.success(
            (await auth.createTokens(user!)).toJson(),
            message: 'Logged in',
          );
        },
        middleware: [
          RateLimitMiddleware(
            maxRequests: 20,
            duration: const Duration(minutes: 1),
          ),
        ],
      );

      app.post('/refresh', (request) async {
        final token = (await request.json())['refresh_token'];
        if (token is! String) {
          return Response.badRequest('refresh_token is required');
        }
        return Response.success((await auth.refresh(token)).toJson());
      });

      app.get('/me', (request) async {
        final u = (await auth.authenticate(request))!;
        return Response.success({
          'id': u.id,
          'email': u.email,
          'roles': u.roles,
        });
      }, middleware: [auth.middleware()]);
    },
  );

  // ---- products: public read, admin write ------------------------------------------
  const sortable = ['id', 'name', 'price', 'created_at'];
  const columns = [
    'id',
    'name',
    'description',
    'price',
    'stock',
    'active',
    'created_at',
    'updated_at',
  ];
  final admin = [
    auth.middleware(),
    auth.requireRole(['admin']),
  ];

  app.group(
    '/api/products',
    routes: () {
      app.get('/', (request) async {
        final search = request.query('search');
        final page = int.tryParse(request.query('page') ?? '') ?? 1;
        final limit = (int.tryParse(request.query('limit') ?? '') ?? 10).clamp(
          1,
          100,
        );
        final result = await db
            .table('products')
            .select(columns)
            .where('active', true)
            .when(
              search != null && search.isNotEmpty,
              (q) => q.whereLike('name', '%$search%'),
            )
            .orderByAllowed(
              request.query('sort'),
              sortable,
              descending: request.query('order') == 'desc',
              fallback: 'id',
            )
            .paginate(page: page < 1 ? 1 : page, limit: limit);
        return Response.success(
          result.data,
          message: 'Products retrieved successfully',
          meta: result.meta,
        );
      });

      app.get('/:id', (request) async {
        final p = await db
            .table('products')
            .select(columns)
            .find(request.param('id')!);
        return p == null
            ? Response.notFound('Product not found')
            : Response.success(p);
      });

      app.post('/', (request) async {
        final v = Validate.request(await request.json(), {
          'name': 'required|string|min:2|max:200',
          'description': 'nullable|string|max:2000',
          'price': 'required|numeric|min:0',
          'stock': 'nullable|integer|min:0',
          'active': 'nullable|boolean',
        });
        if (v.fails) return Response.validationError(v.errors);
        final now = DateTime.now().toUtc();
        final created = await db.table('products').insert({
          ...v.validated,
          'created_at': now,
          'updated_at': now,
        });
        return Response.success(
          await db.table('products').select(columns).find(created['id']!),
          message: 'Product created',
          status: 201,
        );
      }, middleware: admin);

      app.put('/:id', (request) async {
        final v = Validate.request(await request.json(), {
          'name': 'sometimes|string|min:2|max:200',
          'description': 'sometimes|nullable|string|max:2000',
          'price': 'sometimes|numeric|min:0',
          'stock': 'sometimes|integer|min:0',
          'active': 'sometimes|boolean',
        });
        if (v.fails) return Response.validationError(v.errors);
        if (v.validated.isEmpty) {
          return Response.badRequest('Nothing to update');
        }
        final id = request.param('id')!;
        final n = await db.table('products').where('id', id).update({
          ...v.validated,
          'updated_at': DateTime.now().toUtc(),
        });
        if (n == 0) return Response.notFound('Product not found');
        return Response.success(
          await db.table('products').select(columns).find(id),
          message: 'Product updated',
        );
      }, middleware: admin);

      app.delete('/:id', (request) async {
        final n = await db
            .table('products')
            .where('id', request.param('id')!)
            .delete();
        return n == 0
            ? Response.notFound('Product not found')
            : Response.noContent();
      }, middleware: admin);
    },
  );

  return app;
}
