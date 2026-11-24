# dartcore_storage

Local-disk file storage and upload validation for DartCore: safe paths, streaming writes with size limits, and content sniffing.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub add dartcore_storage
```

## Usage

```dart
import 'package:dartcore_storage/dartcore_storage.dart';

Storage.register('local', LocalStorage('storage/app'));
final disk = Storage.disk();                                   // the default disk

await disk.putBytes('org/1/notes.txt', utf8.encode('hello'), maxBytes: 1 << 20);
print(await disk.exists('org/1/notes.txt'));
final stream = disk.read('org/1/notes.txt');                   // Stream<List<int>>
await disk.delete('org/1/notes.txt');

// Validate uploads by their real content, not just the file name.
const rules = FileRules(maxBytes: 5 << 20, allowedMimeTypes: FileRules.documentsAndImages);
final mime = rules.validate(file.filename, file.bytes);        // throws UnsupportedFileException / FileTooLargeException
final name = FileRules.safeName(file.filename);                // strip directories and unsafe characters
```

`LocalStorage` rejects absolute paths, `..` segments and symlink escapes, writes atomically through a temp file and
enforces `maxBytes` while streaming. Failures are typed (`StorageNotFoundException`, `FileTooLargeException`,
`InvalidStoragePathException`, `UnsupportedFileException`). Implement `StorageDisk` to add another backend.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_storage/example/dartcore_storage_example.dart) works in a temp directory.

## Status and limits

Pre-1.0: the API may change. Only the local disk exists: **S3-compatible and Supabase Storage disks are not built**.
`LocalStorage.temporaryUrl` throws `UnsupportedError`: local files are private, serve them through an authorized endpoint.
Content sniffing checks the first bytes only and is not antivirus. See the [implementation status](https://github.com/abqamar/dartcore_framework/blob/main/docs/status.md).
