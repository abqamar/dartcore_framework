import 'dart:convert';
import 'dart:io';

import 'package:dartcore_storage/dartcore_storage.dart';
import 'package:test/test.dart';

const _png = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
];
const _exe = [0x4D, 0x5A, 0x90, 0, 3, 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xFF, 0, 0];

void main() {
  late Directory tmp;
  late LocalStorage disk;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dc_storage');
    disk = LocalStorage('${tmp.path}/root');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> readAll(String p) async =>
      utf8.decode(await disk.read(p).expand((c) => c).toList());

  group('LocalStorage', () {
    test(
      'put/read/exists/size/delete round trip with nested directories',
      () async {
        final f = await disk.putBytes(
          'org/1/tasks/a.txt',
          utf8.encode('hello'),
        );
        expect(f.size, 5);
        expect(await disk.exists('org/1/tasks/a.txt'), isTrue);
        expect(await disk.size('org/1/tasks/a.txt'), 5);
        expect(await readAll('org/1/tasks/a.txt'), 'hello');
        await disk.delete('org/1/tasks/a.txt');
        expect(await disk.exists('org/1/tasks/a.txt'), isFalse);
        await disk.delete('org/1/tasks/a.txt'); // idempotent
      },
    );

    test(
      'streams large writes and enforces the size limit mid-stream, leaving nothing behind',
      () async {
        Stream<List<int>> chunks(int n) =>
            Stream.fromIterable(List.generate(n, (_) => List.filled(1024, 65)));
        expect(
          (await disk.put('big.bin', chunks(10), maxBytes: 20000)).size,
          10240,
        );
        await expectLater(
          disk.put('too-big.bin', chunks(50), maxBytes: 20000),
          throwsA(isA<FileTooLargeException>()),
        );
        expect(await disk.exists('too-big.bin'), isFalse);
        expect(
          Directory(
            '${tmp.path}/root',
          ).listSync().map((e) => e.path.split('/').last),
          isNot(contains(startsWith('too-big'))),
        );
      },
    );

    test('a failing stream removes the partial file', () async {
      Stream<List<int>> broken() async* {
        yield [1, 2, 3];
        throw StateError('connection reset');
      }

      await expectLater(
        disk.put('partial.bin', broken()),
        throwsA(isA<StorageException>()),
      );
      expect(await disk.exists('partial.bin'), isFalse);
      expect(await disk.list(''), isEmpty);
    });

    test(
      'path traversal and malformed paths are rejected everywhere',
      () async {
        for (final bad in [
          '../evil.txt',
          'a/../../evil.txt',
          '/etc/passwd',
          'a//b',
          './a',
          'a/./b',
          r'a\..\b',
          'a/b/',
          '',
          'nul\u0000.txt',
        ]) {
          await expectLater(
            disk.putBytes(bad, [1]),
            throwsA(isA<InvalidStoragePathException>()),
            reason: bad,
          );
          expect(
            () => disk.read(bad),
            throwsA(isA<InvalidStoragePathException>()),
            reason: bad,
          );
          await expectLater(
            disk.exists(bad),
            throwsA(isA<InvalidStoragePathException>()),
            reason: bad,
          );
          await expectLater(
            disk.delete(bad),
            throwsA(isA<InvalidStoragePathException>()),
            reason: bad,
          );
        }
        expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
      },
    );

    test('symlinks pointing outside the root are not followed', () async {
      File('${tmp.path}/secret.txt').writeAsStringSync('top secret');
      Link('${tmp.path}/root/link.txt').createSync('${tmp.path}/secret.txt');
      Directory('${tmp.path}/outside').createSync();
      Link('${tmp.path}/root/dir').createSync('${tmp.path}/outside');
      expect(
        () => disk.read('link.txt'),
        throwsA(isA<InvalidStoragePathException>()),
      );
      await expectLater(
        disk.putBytes('dir/new.txt', [1, 2]),
        throwsA(isA<InvalidStoragePathException>()),
      );
      expect(File('${tmp.path}/outside/new.txt').existsSync(), isFalse);
      await expectLater(
        disk.delete('link.txt'),
        throwsA(isA<InvalidStoragePathException>()),
      );
      expect(File('${tmp.path}/secret.txt').existsSync(), isTrue);
    });

    test(
      'missing files raise a 404-typed exception; list returns relative paths and modification times',
      () async {
        expect(
          () => disk.read('nope.txt'),
          throwsA(isA<StorageNotFoundException>()),
        );
        await expectLater(
          disk.size('nope.txt'),
          throwsA(isA<StorageNotFoundException>()),
        );
        await disk.putBytes('a/1.txt', [1]);
        await disk.putBytes('a/b/2.txt', [1]);
        await disk.putBytes('c/3.txt', [1]);
        final l = await disk.list('a');
        expect(l.map((e) => e.path), unorderedEquals(['a/1.txt', 'a/b/2.txt']));
        expect(l.first.modified.isUtc, isTrue);
        expect((await disk.list('')).length, 3);
        expect(await disk.list('zzz'), isEmpty);
      },
    );

    test('local disks are private: no temporary URLs', () {
      expect(
        () => disk.temporaryUrl('a', const Duration(minutes: 1)),
        throwsUnsupportedError,
      );
    });
  });

  group('FileRules', () {
    const rules = FileRules(
      maxBytes: 100,
      allowedMimeTypes: {'image/png', 'text/plain', 'application/pdf'},
    );

    test('detects by content, not by name', () {
      expect(FileRules.detectMime('x.png', _png), 'image/png');
      expect(FileRules.detectMime('x.png', _exe), isNot('image/png'));
      expect(rules.validate('pic.png', _png), 'image/png');
      expect(
        rules.validate('notes.txt', utf8.encode('plain words')),
        'text/plain',
      );
    });

    test(
      'rejects executables renamed to allowed extensions, disallowed types, empty and oversized files',
      () {
        expect(
          () => rules.validate('pic.png', _exe),
          throwsA(isA<UnsupportedFileException>()),
        );
        expect(
          () => rules.validate('virus.exe', _exe),
          throwsA(isA<UnsupportedFileException>()),
        );
        expect(
          () => rules.validate('empty.txt', const []),
          throwsA(isA<UnsupportedFileException>()),
        );
        expect(
          () => rules.validate('big.png', [..._png, ...List.filled(200, 0)]),
          throwsA(isA<FileTooLargeException>()),
        );
        // a PNG named .pdf is a mismatch
        expect(
          () => rules.validate('fake.pdf', _png),
          throwsA(isA<UnsupportedFileException>()),
        );
      },
    );

    test('safe names and extensions', () {
      expect(FileRules.safeName('../../etc/passwd'), 'passwd');
      expect(FileRules.safeName(r'C:\Users\me\report.pdf'), 'report.pdf');
      expect(FileRules.safeName('a"b<c>.txt'), 'a_b_c_.txt');
      expect(FileRules.safeName('..'), 'file');
      expect(FileRules.safeName('x' * 300 + '.pdf').length, 120);
      expect(FileRules.extensionOf('Photo.JPG'), 'jpg');
      expect(FileRules.extensionOf('noext'), '');
      expect(FileRules.extensionOf('weird.p h p'), '');
    });
  });

  test('Storage facade resolves named disks', () {
    Storage.reset();
    expect(() => Storage.disk(), throwsA(isA<Exception>()));
    Storage.register('local', disk);
    expect(Storage.disk(), same(disk));
    Storage.reset();
  });
}
