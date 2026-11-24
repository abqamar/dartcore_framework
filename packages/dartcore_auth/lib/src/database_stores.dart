import 'package:dartcore_db/dartcore_db.dart';

import 'models.dart';
import 'stores.dart';

/// Database-backed auth stores (works with any DartCore SQL adapter).
///
/// Create the tables once with [DatabaseAuthStores.createTables], or copy the
/// column layout into your own migration.
class DatabaseAuthStores {
  DatabaseAuthStores(this.db);
  final DatabaseOperations db;

  AuthStores get stores => AuthStores(
    refreshTokens: _DbRefresh(db),
    revocations: _DbRevocations(db),
    apiTokens: _DbApi(db),
    passwordResets: _DbReset(db),
  );

  /// Creates the four tables using portable DDL. Safe to call on every boot:
  /// existing tables are left alone.
  static Future<void> createTables(DatabaseOperations db) async {
    final d = db.dialect;
    final bool = d is PostgresDialect
        ? 'BOOLEAN'
        : d is MssqlDialect
        ? 'BIT'
        : d is MySqlDialect
        ? 'TINYINT(1)'
        : 'INTEGER';
    final zero = d is PostgresDialect ? 'FALSE' : '0';
    final ts = d is MssqlDialect
        ? 'DATETIME2'
        : d is PostgresDialect
        ? 'TIMESTAMP'
        : 'DATETIME';
    final text = d is MssqlDialect ? 'NVARCHAR(MAX)' : 'TEXT';
    final str = d is MssqlDialect ? 'NVARCHAR' : 'VARCHAR';
    Future<void> create(String name, String body) async {
      final exists = d is MssqlDialect
          ? 'IF OBJECT_ID(\'$name\', \'U\') IS NULL CREATE TABLE $name ($body)'
          : 'CREATE TABLE IF NOT EXISTS $name ($body)';
      await db.statement(exists);
    }

    await create(
      'auth_refresh_tokens',
      'token_hash $str(64) PRIMARY KEY, family_id $str(64) NOT NULL, user_id $str(64) NOT NULL, '
          'expires_at $ts NOT NULL, used $bool NOT NULL DEFAULT $zero, revoked $bool NOT NULL DEFAULT $zero',
    );
    await create(
      'auth_revoked_tokens',
      'jti $str(64) PRIMARY KEY, expires_at $ts NOT NULL',
    );
    await create(
      'auth_api_tokens',
      'token_hash $str(64) PRIMARY KEY, user_id $str(64) NOT NULL, name $str(120) NOT NULL, '
          'abilities $text NOT NULL, expires_at $ts NULL',
    );
    await create(
      'auth_password_resets',
      'email $str(255) PRIMARY KEY, token_hash $str(64) NOT NULL, expires_at $ts NOT NULL',
    );
  }
}

DateTime _dt(Object? v) {
  if (v is DateTime) return v.toUtc();
  final s = '$v';
  return DateTime.parse(s.endsWith('Z') ? s : '${s}Z').toUtc();
}

bool _bool(Object? v) => v == true || v == 1 || v == '1';

class _DbRefresh implements RefreshTokenStore {
  _DbRefresh(this.db);
  final DatabaseOperations db;

  @override
  Future<void> save(RefreshRecord r) async {
    await db.table('auth_refresh_tokens', primaryKey: 'token_hash').insert({
      'token_hash': r.tokenHash,
      'family_id': r.familyId,
      'user_id': r.userId,
      'expires_at': r.expiresAt.toUtc(),
      'used': r.used,
      'revoked': r.revoked,
    });
  }

  @override
  Future<RefreshRecord?> findByHash(String h) async {
    final row = await db
        .table('auth_refresh_tokens')
        .where('token_hash', h)
        .first();
    if (row == null) return null;
    return RefreshRecord(
      tokenHash: row['token_hash'] as String,
      familyId: row['family_id'] as String,
      userId: row['user_id'] as String,
      expiresAt: _dt(row['expires_at']),
      used: _bool(row['used']),
      revoked: _bool(row['revoked']),
    );
  }

  /// Single conditional UPDATE: exactly one concurrent caller can win.
  @override
  Future<bool> markUsed(String h) async =>
      await db
          .table('auth_refresh_tokens')
          .where('token_hash', h)
          .where('used', false)
          .where('revoked', false)
          .update({'used': true}) ==
      1;

  @override
  Future<void> revokeFamily(String familyId) async {
    await db.table('auth_refresh_tokens').where('family_id', familyId).update({
      'revoked': true,
    });
  }

  @override
  Future<void> revokeAllForUser(String userId) async {
    await db.table('auth_refresh_tokens').where('user_id', userId).update({
      'revoked': true,
    });
  }
}

class _DbRevocations implements RevocationStore {
  _DbRevocations(this.db);
  final DatabaseOperations db;

  @override
  Future<void> revoke(String jti, DateTime expiresAt) async {
    await db
        .table('auth_revoked_tokens')
        .where('expires_at', '<', DateTime.now().toUtc())
        .delete();
    if (await db.table('auth_revoked_tokens').where('jti', jti).exists()) {
      return;
    }
    await db.table('auth_revoked_tokens', primaryKey: 'jti').insert({
      'jti': jti,
      'expires_at': expiresAt.toUtc(),
    });
  }

  @override
  Future<bool> isRevoked(String jti) =>
      db.table('auth_revoked_tokens').where('jti', jti).exists();
}

class _DbApi implements ApiTokenStore {
  _DbApi(this.db);
  final DatabaseOperations db;

  @override
  Future<void> save(ApiTokenRecord r) async {
    await db.table('auth_api_tokens', primaryKey: 'token_hash').insert({
      'token_hash': r.tokenHash,
      'user_id': r.userId,
      'name': r.name,
      'abilities': r.abilities.join(','),
      'expires_at': r.expiresAt?.toUtc(),
    });
  }

  @override
  Future<ApiTokenRecord?> findByHash(String h) async {
    final row = await db
        .table('auth_api_tokens')
        .where('token_hash', h)
        .first();
    if (row == null) return null;
    final abilities = (row['abilities'] as String)
        .split(',')
        .where((s) => s.isNotEmpty)
        .toList();
    return ApiTokenRecord(
      tokenHash: h,
      userId: row['user_id'] as String,
      name: row['name'] as String,
      abilities: abilities,
      expiresAt: row['expires_at'] == null ? null : _dt(row['expires_at']),
    );
  }

  @override
  Future<void> delete(String h) async {
    await db.table('auth_api_tokens').where('token_hash', h).delete();
  }
}

class _DbReset implements PasswordResetStore {
  _DbReset(this.db);
  final DatabaseOperations db;

  @override
  Future<void> save(PasswordResetRecord r) async {
    await delete(r.email);
    await db.table('auth_password_resets', primaryKey: 'email').insert({
      'email': r.email,
      'token_hash': r.tokenHash,
      'expires_at': r.expiresAt.toUtc(),
    });
  }

  @override
  Future<PasswordResetRecord?> find(String email) async {
    final row = await db
        .table('auth_password_resets')
        .where('email', email)
        .first();
    if (row == null) return null;
    return PasswordResetRecord(
      email,
      row['token_hash'] as String,
      _dt(row['expires_at']),
    );
  }

  @override
  Future<void> delete(String email) async {
    await db.table('auth_password_resets').where('email', email).delete();
  }
}
