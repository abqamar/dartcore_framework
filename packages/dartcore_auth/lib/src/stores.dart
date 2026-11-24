import 'models.dart';

/// Persistence for refresh tokens. Only SHA-256 hashes are stored, so a
/// database leak does not leak usable tokens.
abstract interface class RefreshTokenStore {
  Future<void> save(RefreshRecord record);
  Future<RefreshRecord?> findByHash(String tokenHash);

  /// Atomically marks the record used; returns false if it was already used
  /// or revoked (token replay).
  Future<bool> markUsed(String tokenHash);
  Future<void> revokeFamily(String familyId);
  Future<void> revokeAllForUser(String userId);
}

/// Revoked access-token ids (`jti`) until they would have expired anyway.
abstract interface class RevocationStore {
  Future<void> revoke(String jti, DateTime expiresAt);
  Future<bool> isRevoked(String jti);
}

abstract interface class ApiTokenStore {
  Future<void> save(ApiTokenRecord record);
  Future<ApiTokenRecord?> findByHash(String tokenHash);
  Future<void> delete(String tokenHash);
}

class PasswordResetRecord {
  PasswordResetRecord(this.email, this.tokenHash, this.expiresAt);
  final String email, tokenHash;
  final DateTime expiresAt;
}

abstract interface class PasswordResetStore {
  /// Replaces any existing token for [PasswordResetRecord.email].
  Future<void> save(PasswordResetRecord record);
  Future<PasswordResetRecord?> find(String email);
  Future<void> delete(String email);
}

/// In-memory stores for tests and single-process apps. They lose all state on
/// restart; use the database stores in production.
class MemoryRefreshTokenStore implements RefreshTokenStore {
  final Map<String, RefreshRecord> _records = {};

  @override
  Future<void> save(RefreshRecord r) async => _records[r.tokenHash] = r;

  @override
  Future<RefreshRecord?> findByHash(String h) async => _records[h];

  @override
  Future<bool> markUsed(String h) async {
    final r = _records[h];
    if (r == null || r.used || r.revoked) return false;
    r.used = true;
    return true;
  }

  @override
  Future<void> revokeFamily(String familyId) async {
    for (final r in _records.values.where((r) => r.familyId == familyId)) {
      r.revoked = true;
    }
  }

  @override
  Future<void> revokeAllForUser(String userId) async {
    for (final r in _records.values.where((r) => r.userId == userId)) {
      r.revoked = true;
    }
  }
}

class MemoryRevocationStore implements RevocationStore {
  final Map<String, DateTime> _revoked = {};

  @override
  Future<void> revoke(String jti, DateTime expiresAt) async {
    final now = DateTime.now();
    _revoked.removeWhere((_, e) => e.isBefore(now));
    _revoked[jti] = expiresAt;
  }

  @override
  Future<bool> isRevoked(String jti) async => _revoked.containsKey(jti);
}

class MemoryApiTokenStore implements ApiTokenStore {
  final Map<String, ApiTokenRecord> _records = {};
  @override
  Future<void> save(ApiTokenRecord r) async => _records[r.tokenHash] = r;
  @override
  Future<ApiTokenRecord?> findByHash(String h) async => _records[h];
  @override
  Future<void> delete(String h) async => _records.remove(h);
}

class MemoryPasswordResetStore implements PasswordResetStore {
  final Map<String, PasswordResetRecord> _records = {};
  @override
  Future<void> save(PasswordResetRecord r) async => _records[r.email] = r;
  @override
  Future<PasswordResetRecord?> find(String email) async => _records[email];
  @override
  Future<void> delete(String email) async => _records.remove(email);
}

/// All stores an auth service needs.
class AuthStores {
  AuthStores({
    required this.refreshTokens,
    required this.revocations,
    required this.apiTokens,
    required this.passwordResets,
  });

  /// Process-local stores (development and tests).
  factory AuthStores.memory() => AuthStores(
    refreshTokens: MemoryRefreshTokenStore(),
    revocations: MemoryRevocationStore(),
    apiTokens: MemoryApiTokenStore(),
    passwordResets: MemoryPasswordResetStore(),
  );

  final RefreshTokenStore refreshTokens;
  final RevocationStore revocations;
  final ApiTokenStore apiTokens;
  final PasswordResetStore passwordResets;
}
