/// The authenticated principal. Your own user class can wrap or map to this.
class AuthUser {
  const AuthUser({
    required this.id,
    this.email,
    this.roles = const [],
    this.permissions = const [],
    this.attributes = const {},
  });

  final Object id;
  final String? email;
  final List<String> roles;
  final List<String> permissions;

  /// Extra, non-sensitive data you want available on `request`.
  final Map<String, Object?> attributes;

  bool hasRole(String role) => roles.contains(role);

  /// Supports `*` and prefix wildcards: `posts.*` grants `posts.edit`.
  bool can(String permission) => permissions.any(
    (p) =>
        p == '*' ||
        p == permission ||
        (p.endsWith('.*') &&
            permission.startsWith(p.substring(0, p.length - 1))),
  );
}

/// Looks users up. Implement it over your database; DartCore never assumes a
/// users table.
abstract interface class UserRepository {
  Future<AuthUser?> findById(String id);
}

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    this.tokenType = 'Bearer',
  });
  final String accessToken, refreshToken, tokenType;

  /// Access token lifetime in seconds.
  final int expiresIn;

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'token_type': tokenType,
    'expires_in': expiresIn,
  };
}

class RefreshRecord {
  RefreshRecord({
    required this.tokenHash,
    required this.familyId,
    required this.userId,
    required this.expiresAt,
    this.used = false,
    this.revoked = false,
  });
  final String tokenHash, familyId, userId;
  final DateTime expiresAt;
  bool used, revoked;
}

class ApiTokenRecord {
  ApiTokenRecord({
    required this.tokenHash,
    required this.userId,
    required this.name,
    this.abilities = const [],
    this.expiresAt,
  });
  final String tokenHash, userId, name;
  final List<String> abilities;
  final DateTime? expiresAt;
}
