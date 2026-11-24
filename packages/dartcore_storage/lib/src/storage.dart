import 'dart:async';

import 'package:dartcore_core/dartcore_core.dart';

/// A stored object.
class StoredFile {
  const StoredFile(this.path, this.size);
  final String path;
  final int size;
}

class StorageException extends DartCoreException {
  StorageException(super.message, {super.statusCode = 500, super.cause});
}

class StorageNotFoundException extends StorageException {
  StorageNotFoundException(String path)
    : super('File not found.', statusCode: 404, cause: path);
}

class FileTooLargeException extends StorageException {
  FileTooLargeException(int max)
    : super(
        'The file exceeds the maximum size of $max bytes.',
        statusCode: 413,
      );
}

class InvalidStoragePathException extends StorageException {
  InvalidStoragePathException(String path)
    : super('Invalid storage path.', statusCode: 400, cause: path);
}

class UnsupportedFileException extends StorageException {
  UnsupportedFileException(super.message) : super(statusCode: 422);
}

/// A place files can be written to. Implementations: [LocalStorage]; S3-compatible
/// and Supabase Storage disks are not implemented yet.
abstract interface class StorageDisk {
  /// Writes [data] to [path], creating directories. Throws [FileTooLargeException]
  /// as soon as more than [maxBytes] have been received (the partial file is removed).
  Future<StoredFile> put(String path, Stream<List<int>> data, {int? maxBytes});

  Future<StoredFile> putBytes(String path, List<int> bytes, {int? maxBytes});

  /// Streams the file. Throws [StorageNotFoundException] if missing.
  Stream<List<int>> read(String path);

  Future<bool> exists(String path);
  Future<int> size(String path);
  Future<void> delete(String path);

  /// Paths (relative to the disk root) under [prefix] with their last-modified time.
  Future<List<({String path, DateTime modified})>> list(String prefix);

  /// Signed/temporary public URL, for disks that support it. Local disks are
  /// private by design and throw [UnsupportedError]; serve downloads through
  /// your API after an authorization check.
  Future<String> temporaryUrl(String path, Duration expiresIn);
}

/// Static facade over named disks: `Storage.disk().putBytes(...)`.
abstract final class Storage {
  static final Map<String, StorageDisk> _disks = {};
  static String _default = 'local';

  static void register(
    String name,
    StorageDisk disk, {
    bool makeDefault = false,
  }) {
    _disks[name] = disk;
    if (makeDefault || _disks.length == 1) _default = name;
  }

  static StorageDisk disk([String? name]) =>
      _disks[name ?? _default] ??
      (throw ConfigurationException(
        'Storage disk "${name ?? _default}" is not registered.',
      ));

  static void reset() => _disks.clear();
}
