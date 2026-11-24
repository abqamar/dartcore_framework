# Authentication and authorization (`dartcore_auth`)

```dart
class DbUsers implements UserRepository {               // you decide where users live
  @override
  Future<AuthUser?> findById(String id) async {
    final row = await DB.table('users').select(['id', 'email', 'role']).find(id);
    return row == null ? null : AuthUser(id: row['id']!, email: row['email'] as String?, roles: [row['role'] as String]);
  }
}

final auth = AuthService(
  secret: Config.require('JWT_SECRET'),                 // >= 32 bytes, placeholders rejected
  users: DbUsers(),
  stores: DatabaseAuthStores(DB.connection()).stores,   // production: persistent stores
);
await DatabaseAuthStores.createTables(DB.connection());  // idempotent
Auth.configure(auth);                                     // optional: enables the static Auth.* helpers
```

## Register / login / refresh / logout

```dart
final hash = await auth.hashPassword(password);                    // Argon2id; store it
final ok   = await auth.checkPassword(password, storedHash);       // constant time
final tokens = await auth.createTokens(user);     // TokenPair: accessToken (JWT, 15 min), refreshToken (opaque, 30 d)
return Response.success(tokens.toJson());         // access_token, refresh_token, token_type, expires_in

final next = await auth.refresh(refreshToken);    // rotation: the old refresh token is now dead
await auth.logout(request, refreshToken: rt);     // revokes the access token's jti and the refresh family
await auth.revokeAllSessions(userId);             // e.g. after a password change
```

Replaying a used refresh token revokes the whole chain and throws `AuthenticationException`. Always return the same message
for "unknown email" and "wrong password".

## Protecting routes

```dart
app.group('/admin', middleware: [Auth.middleware(), Auth.role(['admin'])], routes: () {
  app.get('/dashboard', dashboardHandler);
});
app.delete('/posts/:id', handler, middleware: [Auth.middleware(), Auth.can(['posts.delete'])]);

final user = await Auth.user(request);   // AuthUser? (id, email, roles, permissions)
```

* Without the static facade (for example in tests, or with several `AuthService` instances) use the instance methods:
  `auth.middleware()`, `auth.requireRole([...])` and `auth.requirePermission([...])`.
* `middleware()` → 401 with `WWW-Authenticate: Bearer`; `middleware(optional: true)` lets anonymous requests through.
* Credentials are read from `Authorization: Bearer <jwt|dc_… api token>`, `X-API-Key`, or a cookie (`cookieName:`).
* `role([...])` requires any listed role; `can([...])` requires all permissions. Permissions support wildcards: `*` and
  `posts.*`. Both answer 403 (401 if no user).
* With a `UserRepository`, roles/permissions are re-read from storage on each request (a demoted user loses access
  immediately); without one they come from the (up to 15 min stale) token.

## API tokens, password reset, sessions

```dart
final plain = await auth.createApiToken('42', 'ci-deploy', abilities: ['read:data'], ttl: Duration(days: 90)); // shown once
await auth.revokeApiToken(plain);

final reset = await auth.createPasswordResetToken('user@example.com');   // email it; answer identically for unknown emails
final valid = await auth.consumePasswordResetToken('user@example.com', reset);  // single use, 1 h

final sessions = SessionManager(secureCookie: true);                     // server-side cookie sessions
return sessions.start(Response.ok({}), userId);   ...   sessions.current(request);   ...   sessions.destroy(request, Response.ok({}));
```

Cookie tokens: `auth.withTokenCookies(response, pair)` sets `HttpOnly; Secure; SameSite=Strict` cookies. Add CSRF
protection if you authenticate state-changing requests by cookie.

See [SECURITY.md](../SECURITY.md) for the full list of guarantees and gaps.
