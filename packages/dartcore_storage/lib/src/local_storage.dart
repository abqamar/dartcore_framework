import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'storage.dart';

/// Stores files under [root] on the local filesystem.
///
/// Safety: paths must be relative, use `/`, and may not contain `..`, empty
/// or NUL segments; the resolved location (after following symlinks) must
/// stay inside the root. Writes go to a temporary file first and are renamed
/// into place, so readers never see a half-written file.
class LocalStorage implements StorageDisk {
  LocalStorage(String root) : _root = Directory(root).absolute {
    _root.createSync(recursive: true);
    _canonicalRoot = _root.resolveSymbolicLinksSync();
  }

  final Directory _root;
  late final String _canonicalRoot;
  static final _rng = Random.secure();

  /// Validates [path] and returns the absolute file location.
  File _file(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000')) {
      throw InvalidStoragePathException(path);
    }
    final segments = path.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw InvalidStoragePathException(path);
    }
    return File('$_canonicalRoot/${segments.join('/')}');
  }

  void _assertInside(String resolved, String original) {
    if (resolved != _canonicalRoot &&
        !resolved.startsWith('$_canonicalRoot/')) {
      throw InvalidStoragePathException(original);
    }
  }

  @override
  Future<StoredFile> put(
    String path,
    Stream<List<int>> data, {
    int? maxBytes,
  }) async {
    final target = _file(path);
    await target.parent.create(recursive: true);
    _assertInside(await target.parent.resolveSymbolicLinks(), path);
    final tmp = File(
      '${target.path}.tmp-${_rng.nextInt(1 << 32).toRadixString(16)}',
    );
    final sink = tmp.openWrite();
    var written = 0;
    try {
      await for (final chunk in data) {
        written += chunk.length;
        if (maxBytes != null && written > maxBytes) {
          throw FileTooLargeException(maxBytes);
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      await tmp.rename(target.path);
      return StoredFile(path, written);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      if (e is StorageException) rethrow;
      throw StorageException('Could not store the file.', cause: e);
    }
  }

  @override
  Future<StoredFile> putBytes(String path, List<int> bytes, {int? maxBytes}) =>
      put(path, Stream.value(bytes), maxBytes: maxBytes);

  @override
  Stream<List<int>> read(String path) {
    final f = _file(path);
    if (!f.existsSync()) throw StorageNotFoundException(path);
    _assertInside(f.resolveSymbolicLinksSync(), path);
    return f.openRead();
  }

  @override
  Future<bool> exists(String path) async {
    final f = _file(path);
    return f.exists();
  }

  @override
  Future<int> size(String path) async {
    final f = _file(path);
    if (!await f.exists()) throw StorageNotFoundException(path);
    return f.length();
  }

  @override
  Future<void> delete(String path) async {
    final f = _file(path);
    if (await f.exists()) {
      _assertInside(await f.resolveSymbolicLinks(), path);
      await f.delete();
    }
  }

  @override
  Future<List<({String path, DateTime modified})>> list(String prefix) async {
    final dir = Directory(prefix.isEmpty ? _canonicalRoot : _file(prefix).path);
    if (!await dir.exists()) return const [];
    final out = <({String path, DateTime modified})>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && !e.path.contains('.tmp-')) {
        out.add((
          path: e.path.substring(_canonicalRoot.length + 1),
          modified: (await e.lastModified()).toUtc(),
        ));
      }
    }
    return out;
  }

  @override
  Future<String> temporaryUrl(String path, Duration expiresIn) =>
      throw UnsupportedError(
        'LocalStorage is private; serve files through an authorized endpoint.',
      );
}
