# dartcore_auth

Authentication for DartCore: Argon2id passwords, JWT with rotating refresh tokens, API tokens, sessions and role-based access control.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub add dartcore_auth
```

Needs `dartcore_api` and, for persistent token stores, `dartcore_db` with an adapter.

## Usage

```dart
import 'package:dartcore_auth/dartcore_auth.dart';

class DbUsers implements UserRepository {          // you decide where users live
  @override
  Future<AuthUser?> findById(String id) async { /* load from your database */ }
}

final auth = AuthService(
  secret: Config.require('JWT_SECRET'),            // at least 32 bytes; placeholders are rejected
  users: DbUsers(),
  stores: DatabaseAuthStores(DB.connection()).stores,   // persistent stores (default is in memory)
);
await DatabaseAuthStores.createTables(DB.connection());  // idempotent

final hash = await auth.hashPassword(password);            // Argon2id
final ok = await auth.checkPassword(password, hash);
final tokens = await auth.createTokens(user);              // JWT access token + rotating refresh token
final next = await auth.refresh(tokens.refreshToken);      // replaying the old one revokes the chain

app.get('/admin', handler, middleware: [auth.middleware(), auth.requireRole(['admin'])]);
app.delete('/posts/:id', handler, middleware: [auth.middleware(), auth.requirePermission(['posts.delete'])]);
```

Also included: API tokens (`createApiToken`), password-reset tokens, server-side cookie sessions (`SessionManager`),
wildcard permissions (`posts.*`) and optional static helpers (`Auth.configure(auth)`, `Auth.middleware()`, `Auth.role`, `Auth.can`).
Credentials are read from `Authorization: Bearer`, `X-API-Key` or a cookie.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_auth/example/dartcore_auth_example.dart) uses SQLite `:memory:`.

## Status and limits

Pre-1.0 and security-sensitive: **review it before protecting real data**; it has not had an independent audit.
The in-memory stores are per process; use `DatabaseAuthStores` in production. Add CSRF protection if you authenticate
state-changing requests with cookies. See the [auth guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/auth.md) and
[SECURITY.md](https://github.com/abqamar/dartcore_framework/blob/main/SECURITY.md) for guarantees and known gaps.
