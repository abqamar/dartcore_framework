import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartcore_api/dartcore_api.dart';
import 'package:dartcore_core/dartcore_core.dart';

import 'models.dart';
import 'password.dart';
import 'stores.dart';

/// Verified access-token claims.
class AccessClaims {
  AccessClaims({
    required this.subject,
    required this.jti,
    required this.expiresAt,
    this.email,
    this.roles = const [],
    this.permissions = const [],
  });
  final String subject, jti;
  final DateTime expiresAt;
  final String? email;
  final List<String> roles, permissions;
}

/// JWT access tokens, rotating refresh tokens, API tokens, password-reset
/// tokens and password hashing.
///
/// Security properties:
/// * Access tokens are HS256 JWTs. Only HS256 is accepted (no `alg: none`, no
///   algorithm confusion); `iss`, `aud` and `exp` are verified; the secret must
///   be at least 32 bytes.
/// * Refresh tokens are opaque random values stored only as SHA-256 hashes and
///   are **single-use**: presenting a used token revokes the whole token family
///   (replay detection).
/// * Logout revokes the access token's `jti` until its natural expiry.
/// * Tokens and passwords are never logged.
class AuthService {
  AuthService({
    required String secret,
    this.issuer = 'dartcore',
    this.audience = 'dartcore-api',
    this.accessTtl = const Duration(minutes: 15),
    this.refreshTtl = const Duration(days: 30),
    PasswordHasher? hasher,
    this.users,
    AuthStores? stores,
  }) : _secret = _checkSecret(secret),
       hasher = hasher ?? Argon2idHasher(),
       stores = stores ?? AuthStores.memory();

  /// Convenience: reads `JWT_SECRET` (and optional `JWT_ISSUER`, `JWT_AUDIENCE`).
  factory AuthService.fromConfig(
    ConfigRepository config, {
    UserRepository? users,
    AuthStores? stores,
  }) => AuthService(
    secret: config.require('JWT_SECRET'),
    issuer: config.get('JWT_ISSUER', 'dartcore')!,
    audience: config.get('JWT_AUDIENCE', 'dartcore-api')!,
    users: users,
    stores: stores,
  );

  final String _secret;
  final String issuer, audience;
  final Duration accessTtl, refreshTtl;
  final PasswordHasher hasher;
  final UserRepository? users;
  final AuthStores stores;
  static final _rng = Random.secure();

  static String _checkSecret(String s) {
    const weak = {'replace_me', 'secret', 'changeme', 'change_me', 'password'};
    if (utf8.encode(s).length < 32 || weak.contains(s.toLowerCase())) {
      throw ConfigurationException(
        'JWT secret must be at least 32 bytes and not a placeholder. '
        'Generate one with: openssl rand -base64 48',
      );
    }
    return s;
  }

  static String _random(int bytes) => base64Url
      .encode(List.generate(bytes, (_) => _rng.nextInt(256)))
      .replaceAll('=', '');

  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  // ---- passwords --------------------------------------------------------------

  Future<String> hashPassword(String password) => hasher.hash(password);
  Future<bool> checkPassword(String password, String hash) =>
      hasher.verify(password, hash);

  // ---- token issuing / verification ----------------------------------------------

  /// Issues an access + refresh token pair for [user], starting a new
  /// refresh-token family.
  Future<TokenPair> createTokens(AuthUser user, {Duration? accessTtl}) =>
      _issue(user, _random(16), accessTtl);

  Future<TokenPair> _issue(
    AuthUser user,
    String familyId,
    Duration? accessOverride,
  ) async {
    final ttl = accessOverride ?? accessTtl;
    final jwt = JWT(
      {
        'roles': user.roles,
        'permissions': user.permissions,
        'email': ?user.email,
      },
      subject: user.id.toString(),
      issuer: issuer,
      audience: Audience([audience]),
      jwtId: _random(16),
    );
    final access = jwt.sign(
      SecretKey(_secret),
      algorithm: JWTAlgorithm.HS256,
      expiresIn: ttl,
    );
    final refresh = 'rt_${_random(32)}';
    await stores.refreshTokens.save(
      RefreshRecord(
        tokenHash: hashToken(refresh),
        familyId: familyId,
        userId: user.id.toString(),
        expiresAt: DateTime.now().add(refreshTtl),
      ),
    );
    return TokenPair(
      accessToken: access,
      refreshToken: refresh,
      expiresIn: ttl.inSeconds,
    );
  }

  /// Verifies an access token (signature, algorithm, iss, aud, exp, revocation).
  Future<AccessClaims> verifyAccessToken(String token) async {
    _requireHs256(token);
    final JWT jwt;
    try {
      jwt = JWT.verify(
        token,
        SecretKey(_secret),
        issuer: issuer,
        audience: Audience([audience]),
      );
    } on JWTExpiredException {
      throw AuthenticationException('Token has expired.');
    } on JWTException {
      throw AuthenticationException('Invalid token.');
    }
    final payload = jwt.payload is Map
        ? (jwt.payload as Map).cast<String, Object?>()
        : <String, Object?>{};
    final jti = jwt.jwtId, sub = jwt.subject, exp = payload['exp'];
    if (jti == null || sub == null || exp is! int) {
      throw AuthenticationException('Invalid token.');
    }
    if (await stores.revocations.isRevoked(jti)) {
      throw AuthenticationException('Token has been revoked.');
    }
    List<String> strings(Object? v) =>
        v is List ? v.map((e) => '$e').toList() : const [];
    return AccessClaims(
      subject: sub,
      jti: jti,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp * 1000),
      email: payload['email'] as String?,
      roles: strings(payload['roles']),
      permissions: strings(payload['permissions']),
    );
  }

  /// Rejects anything but `{"alg":"HS256","typ":"JWT"}` before the library
  /// sees the token (blocks `alg: none` and algorithm-confusion attempts).
  void _requireHs256(String token) {
    final parts = token.split('.');
    if (parts.length != 3) throw AuthenticationException('Invalid token.');
    try {
      final header =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
              )
              as Map;
      if (header['alg'] != 'HS256') {
        throw AuthenticationException('Invalid token.');
      }
    } on FormatException {
      throw AuthenticationException('Invalid token.');
    } on TypeError {
      throw AuthenticationException('Invalid token.');
    }
  }

  /// Exchanges a refresh token for a new pair (rotation). Replay of an
  /// already-used token revokes the whole family and fails.
  Future<TokenPair> refresh(String refreshToken) async {
    final repo =
        users ??
        (throw ConfigurationException(
          'AuthService.refresh needs a UserRepository.',
        ));
    final hash = hashToken(refreshToken);
    final rec = await stores.refreshTokens.findByHash(hash);
    if (rec == null) throw AuthenticationException('Invalid refresh token.');
    if (rec.used || rec.revoked) {
      await stores.refreshTokens.revokeFamily(rec.familyId);
      throw AuthenticationException(
        'Refresh token reuse detected; all sessions in this chain were revoked.',
      );
    }
    if (rec.expiresAt.isBefore(DateTime.now())) {
      throw AuthenticationException('Refresh token has expired.');
    }
    if (!await stores.refreshTokens.markUsed(hash)) {
      await stores.refreshTokens.revokeFamily(rec.familyId);
      throw AuthenticationException(
        'Refresh token reuse detected; all sessions in this chain were revoked.',
      );
    }
    final user = await repo.findById(rec.userId);
    if (user == null) {
      await stores.refreshTokens.revokeFamily(rec.familyId);
      throw AuthenticationException('User no longer exists.');
    }
    return _issue(user, rec.familyId, null);
  }

  /// Revokes the access token (until it expires) and, if given, the refresh
  /// token's whole family.
  Future<void> revoke(String accessToken, {String? refreshToken}) async {
    final claims = await verifyAccessToken(accessToken);
    await stores.revocations.revoke(claims.jti, claims.expiresAt);
    if (refreshToken != null) {
      final rec = await stores.refreshTokens.findByHash(
        hashToken(refreshToken),
      );
      if (rec != null) await stores.refreshTokens.revokeFamily(rec.familyId);
    }
  }

  /// Invalidates every refresh token of [userId] (call after a password change).
  Future<void> revokeAllSessions(String userId) =>
      stores.refreshTokens.revokeAllForUser(userId);

  // ---- API tokens --------------------------------------------------------------

  /// Creates a long-lived API token. The plaintext is returned **once**; only
  /// its hash is stored.
  Future<String> createApiToken(
    String userId,
    String name, {
    List<String> abilities = const [],
    Duration? ttl,
  }) async {
    final plain = 'dc_${_random(32)}';
    await stores.apiTokens.save(
      ApiTokenRecord(
        tokenHash: hashToken(plain),
        userId: userId,
        name: name,
        abilities: abilities,
        expiresAt: ttl == null ? null : DateTime.now().add(ttl),
      ),
    );
    return plain;
  }

  Future<void> revokeApiToken(String plain) =>
      stores.apiTokens.delete(hashToken(plain));

  Future<AuthUser> _authenticateApiToken(String plain) async {
    final rec = await stores.apiTokens.findByHash(hashToken(plain));
    if (rec == null || (rec.expiresAt?.isBefore(DateTime.now()) ?? false)) {
      throw AuthenticationException('Invalid API token.');
    }
    final base = await users?.findById(rec.userId);
    if (base == null && users != null) {
      throw AuthenticationException('Invalid API token.');
    }
    return AuthUser(
      id: rec.userId,
      email: base?.email,
      roles: base?.roles ?? const [],
      // an ability list narrows what the token may do
      permissions: rec.abilities.isNotEmpty
          ? rec.abilities
          : (base?.permissions ?? const []),
      attributes: {'api_token': rec.name},
    );
  }

  // ---- password reset ----------------------------------------------------------

  /// Creates a single-use reset token for [email] (valid for [ttl]). Send the
  /// returned plaintext by email; respond identically whether or not the
  /// account exists to avoid user enumeration.
  Future<String> createPasswordResetToken(
    String email, {
    Duration ttl = const Duration(hours: 1),
  }) async {
    final plain = _random(32);
    await stores.passwordResets.save(
      PasswordResetRecord(
        email.toLowerCase(),
        hashToken(plain),
        DateTime.now().add(ttl),
      ),
    );
    return plain;
  }

  /// Validates and **consumes** the token. Returns false for unknown,
  /// expired or already-used tokens.
  Future<bool> consumePasswordResetToken(String email, String token) async {
    final key = email.toLowerCase();
    final rec = await stores.passwordResets.find(key);
    if (rec == null) return false;
    final ok =
        constantTimeEquals(
          utf8.encode(rec.tokenHash),
          utf8.encode(hashToken(token)),
        ) &&
        rec.expiresAt.isAfter(DateTime.now());
    if (ok || rec.expiresAt.isBefore(DateTime.now())) {
      await stores.passwordResets.delete(key);
    }
    return ok;
  }

  // ---- request integration ---------------------------------------------------

  static const _userKey = 'auth_user';
  static const _claimsKey = 'auth_claims';
  static const _tokenKey = 'auth_token';

  String? _extractToken(Request request, String? cookieName) {
    final h = request.header('authorization');
    if (h != null &&
        h.length > 7 &&
        h.substring(0, 7).toLowerCase() == 'bearer ') {
      return h.substring(7).trim();
    }
    final api = request.header('x-api-key');
    if (api != null && api.isNotEmpty) return api;
    return cookieName == null ? null : request.cookie(cookieName);
  }

  /// Authenticates [request] (bearer JWT, `dc_` API token, or cookie).
  /// Returns null when no credentials were presented; throws
  /// [AuthenticationException] when they are invalid.
  Future<AuthUser?> authenticate(Request request, {String? cookieName}) async {
    final cached = request.attributes[_userKey];
    if (cached is AuthUser) return cached;
    final token = _extractToken(request, cookieName);
    if (token == null) return null;
    AuthUser user;
    if (token.startsWith('dc_')) {
      user = await _authenticateApiToken(token);
    } else {
      final claims = await verifyAccessToken(token);
      final fresh = await users?.findById(claims.subject);
      if (users != null && fresh == null) {
        throw AuthenticationException('User no longer exists.');
      }
      user =
          fresh ??
          AuthUser(
            id: claims.subject,
            email: claims.email,
            roles: claims.roles,
            permissions: claims.permissions,
          );
      request.attributes[_claimsKey] = claims;
    }
    request.attributes[_tokenKey] = token;
    request.attributes[_userKey] = user;
    return user;
  }

  /// Requires authentication. With [optional] unauthenticated requests pass
  /// through (with no user) instead of getting 401.
  Middleware middleware({bool optional = false, String? cookieName}) =>
      Middleware.from((request, next) async {
        try {
          final user = await authenticate(request, cookieName: cookieName);
          if (user == null && !optional) {
            return _unauthorized('Authentication required.');
          }
        } on AuthenticationException catch (e) {
          return _unauthorized(e.message);
        }
        return next(request);
      });

  /// Allows requests whose user has **any** of [roles].
  Middleware requireRole(List<String> roles) =>
      Middleware.from((request, next) async {
        final user = request.attributes[_userKey] as AuthUser?;
        if (user == null) return _unauthorized('Authentication required.');
        if (!roles.any(user.hasRole)) {
          return Response.forbidden('You do not have the required role.');
        }
        return next(request);
      });

  /// Allows requests whose user has **all** of [permissions].
  Middleware requirePermission(List<String> permissions) =>
      Middleware.from((request, next) async {
        final user = request.attributes[_userKey] as AuthUser?;
        if (user == null) return _unauthorized('Authentication required.');
        if (!permissions.every(user.can)) {
          return Response.forbidden('You do not have permission to do that.');
        }
        return next(request);
      });

  Response _unauthorized(String message) =>
      Response.unauthorized(message).withHeader('www-authenticate', 'Bearer');

  /// Sets the token pair as secure cookies (`HttpOnly`, `Secure`,
  /// `SameSite=Strict`). Cookie auth needs CSRF defences for unsafe methods.
  Response withTokenCookies(
    Response response,
    TokenPair pair, {
    String accessCookie = 'access_token',
    String refreshCookie = 'refresh_token',
    bool secure = true,
  }) {
    return response
        .cookie(
          accessCookie,
          pair.accessToken,
          maxAge: Duration(seconds: pair.expiresIn),
          secure: secure,
          sameSite: 'Strict',
        )
        .cookie(
          refreshCookie,
          pair.refreshToken,
          maxAge: refreshTtl,
          path: '/auth',
          secure: secure,
          sameSite: 'Strict',
        );
  }

  /// Revokes the request's access token (and [refreshToken]'s family).
  Future<void> logout(Request request, {String? refreshToken}) async {
    final token =
        request.attributes[_tokenKey] as String? ??
        _extractToken(request, null);
    if (token == null || token.startsWith('dc_')) {
      if (token != null) await revokeApiToken(token);
      return;
    }
    await revoke(token, refreshToken: refreshToken);
  }
}

/// Static facade over a managed default [AuthService].
///
/// ```dart
/// Auth.configure(AuthService(secret: Config.require('JWT_SECRET'), users: repo));
/// final tokens = await Auth.createToken(user);
/// app.group('/admin', middleware: [Auth.middleware()], routes: () {...});
/// ```
abstract final class Auth {
  static AuthService? _service;

  static void configure(AuthService service) => _service = service;
  static void reset() => _service = null;

  static AuthService get service =>
      _service ??
      (throw ConfigurationException(
        'Auth is not configured. Call Auth.configure(AuthService(...)).',
      ));

  static Future<TokenPair> createToken(AuthUser user) =>
      service.createTokens(user);
  static Future<AuthUser?> user(Request request) =>
      service.authenticate(request);
  static Future<void> logout(Request request, {String? refreshToken}) =>
      service.logout(request, refreshToken: refreshToken);

  // These resolve the service when a request arrives, not when routes are
  // registered, so `route:list`, tests and tooling can build the route table
  // before (or without) configuring auth.
  static Middleware middleware({bool optional = false, String? cookieName}) =>
      Middleware.from(
        (r, next) => service
            .middleware(optional: optional, cookieName: cookieName)
            .handle(r, next),
      );
  static Middleware role(List<String> roles) =>
      Middleware.from((r, next) => service.requireRole(roles).handle(r, next));
  static Middleware can(List<String> permissions) => Middleware.from(
    (r, next) => service.requirePermission(permissions).handle(r, next),
  );
  static Future<String> hashPassword(String p) => service.hashPassword(p);
  static Future<bool> checkPassword(String p, String hash) =>
      service.checkPassword(p, hash);
}
