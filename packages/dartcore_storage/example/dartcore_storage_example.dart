// Local disk storage and upload validation in a temp directory (ran for real).
//
// Observed output of `dart run example/dartcore_storage_example.dart`:
//
//   stored org/1/notes.txt (13 bytes)
//   exists: true
//   read back: hello storage
//   list: [org/1/notes.txt]
//   "../escape.txt" -> InvalidStoragePathException
//   100 bytes with maxBytes: 10 -> FileTooLargeException
//   plain text mime: text/plain
//   exe renamed to photo.png -> Files of type "application/octet-stream" are not allowed.
//   safeName: evil name_.txt

import 'dart:convert';
import 'dart:io';

import 'package:dartcore_storage/dartcore_storage.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('dartcore_storage_example');
  try {
    Storage.register('local', LocalStorage('${dir.path}/files'));
    final disk = Storage.disk();

    final stored = await disk.putBytes(
      'org/1/notes.txt',
      utf8.encode('hello storage'),
    );
    print('stored ${stored.path} (${stored.size} bytes)');
    print('exists: ${await disk.exists('org/1/notes.txt')}');
    final text = utf8.decode(
      await disk.read('org/1/notes.txt').expand((c) => c).toList(),
    );
    print('read back: $text');
    print('list: ${(await disk.list('org/1')).map((f) => f.path).toList()}');

    // Path traversal is refused.
    try {
      await disk.putBytes('../escape.txt', [1]);
    } on InvalidStoragePathException {
      print('"../escape.txt" -> InvalidStoragePathException');
    }

    // Size limits are enforced while writing.
    try {
      await disk.putBytes('big.bin', List.filled(100, 0), maxBytes: 10);
    } on FileTooLargeException {
      print('100 bytes with maxBytes: 10 -> FileTooLargeException');
    }

    // Upload validation sniffs the real content, not just the file name.
    const rules = FileRules(
      maxBytes: 1024,
      allowedMimeTypes: FileRules.documentsAndImages,
    );
    print(
      'plain text mime: ${rules.validate('a.txt', utf8.encode('just text'))}',
    );
    final exe = [0x4D, 0x5A, 0x90, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xFF, 0, 0];
    try {
      rules.validate('photo.png', exe);
    } on UnsupportedFileException catch (e) {
      print('exe renamed to photo.png -> ${e.message}');
    }
    print('safeName: ${FileRules.safeName(r'..\..\evil name?.txt')}');

    await disk.delete('org/1/notes.txt');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
