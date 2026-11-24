import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

abstract interface class PasswordHasher {
  Future<String> hash(String password);
  Future<bool> verify(String password, String hash);

  /// True when [hash] was made with weaker parameters than the current ones.
  bool needsRehash(String hash);
}

/// Argon2id via `package:cryptography`, stored in PHC string format:
/// `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`.
///
/// Defaults follow the OWASP minimum (19 MiB, 2 iterations, 1 lane). This is a
/// pure-Dart implementation: expect tens to hundreds of milliseconds per hash
/// and run it sparingly (login/register, not per request).
class Argon2idHasher implements PasswordHasher {
  Argon2idHasher({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
    this.hashLength = 32,
  });

  final int memoryKiB, iterations, parallelism, hashLength;
  static final _rng = Random.secure();
  static const _sep = r'$';

  Argon2id _algo(int m, int t, int p, int len) =>
      Argon2id(memory: m, iterations: t, parallelism: p, hashLength: len);

  static String _b64(List<int> b) => base64.encode(b).replaceAll('=', '');

  @override
  Future<String> hash(String password) async {
    final salt = Uint8List.fromList(
      List.generate(16, (_) => _rng.nextInt(256)),
    );
    final key = await _algo(
      memoryKiB,
      iterations,
      parallelism,
      hashLength,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final bytes = await key.extractBytes();
    return [
      '',
      'argon2id',
      'v=19',
      'm=$memoryKiB,t=$iterations,p=$parallelism',
      _b64(salt),
      _b64(bytes),
    ].join(_sep);
  }

  @override
  Future<bool> verify(String password, String hash) async {
    final parts = hash.split(_sep);
    // ['', 'argon2id', 'v=19', 'm=..,t=..,p=..', salt, hash]
    if (parts.length != 6 || parts[1] != 'argon2id') return false;
    final params = {
      for (final kv in parts[3].split(','))
        if (kv.contains('=')) kv.split('=')[0]: int.tryParse(kv.split('=')[1]),
    };
    final m = params['m'], t = params['t'], p = params['p'];
    if (m == null || t == null || p == null) return false;
    // Refuse absurd parameters from a tampered hash (memory-exhaustion DoS).
    if (m > 1024 * 1024 || t > 20 || p > 16) return false;
    try {
      final salt = base64.decode(base64.normalize(parts[4]));
      final expected = base64.decode(base64.normalize(parts[5]));
      final key = await _algo(
        m,
        t,
        p,
        expected.length,
      ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      return constantTimeEquals(await key.extractBytes(), expected);
    } on FormatException {
      return false;
    }
  }

  @override
  bool needsRehash(String hash) {
    final m = RegExp(r'm=(\d+),t=(\d+),p=(\d+)').firstMatch(hash);
    if (m == null) return true;
    return int.parse(m.group(1)!) < memoryKiB ||
        int.parse(m.group(2)!) < iterations ||
        int.parse(m.group(3)!) < parallelism;
  }
}

/// Constant-time byte comparison.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
