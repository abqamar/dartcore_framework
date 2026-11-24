import 'package:dartcore_framework/dartcore_framework.dart';
import 'package:dartcore_auth/dartcore_auth.dart';

/// Maps rows of the `users` table to [AuthUser]s.
class DbUserRepository implements UserRepository {
  @override
  Future<AuthUser?> findById(String id) async {
    final row = await DB.table('users').find(id);
    if (row == null) return null;
    return AuthUser(
      id: row['id']!,
      email: row['email'] as String?,
      roles: const ['user'],
    );
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
        final taken = await DB
            .table('users')
            .where('email', v.get<String>('email')!.toLowerCase())
            .exists();
        if (taken) {
          return Response.validationError({
            'email': ['The email has already been taken.'],
          });
        }
        final user = await DB.table('users').insert({
          'name': v.get<String>('name'),
          'email': v.get<String>('email')!.toLowerCase(),
          'password': await auth.hashPassword(v.get<String>('password')!),
        });
        final tokens = await auth.createTokens(
          AuthUser(
            id: user['id']!,
            email: user['email'] as String?,
            roles: const ['user'],
          ),
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
          final row = await DB
              .table('users')
              .where('email', v.get<String>('email')!.toLowerCase())
              .first();
          // Same message for unknown email and wrong password (no user enumeration).
          final ok =
              row != null &&
              await auth.checkPassword(
                v.get<String>('password')!,
                row['password'] as String,
              );
          if (!ok) return Response.unauthorized('Invalid credentials');
          final tokens = await auth.createTokens(
            AuthUser(
              id: row['id']!,
              email: row['email'] as String?,
              roles: const ['user'],
            ),
          );
          return Response.success(tokens.toJson(), message: 'Logged in');
        },
        middleware: [
          RateLimitMiddleware(
            maxRequests: 10,
            duration: const Duration(minutes: 1),
          ),
        ],
      );

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
        return Response.success({
          'id': user!.id,
          'email': user.email,
          'roles': user.roles,
        });
      }, middleware: [Auth.middleware()]);

      app.post('/logout', (request) async {
        final body = await request.json().catchError(
          (_) => <String, dynamic>{},
        );
        await Auth.logout(
          request,
          refreshToken: body['refresh_token'] as String?,
        );
        return Response.success(null, message: 'Logged out');
      }, middleware: [Auth.middleware()]);
    },
  );
}
