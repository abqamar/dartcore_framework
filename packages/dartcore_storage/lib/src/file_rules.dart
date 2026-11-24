import 'dart:convert';

import 'package:mime/mime.dart';

import 'storage.dart';

/// Validates an upload by **content**, not by what the client claims.
class FileRules {
  const FileRules({required this.maxBytes, required this.allowedMimeTypes});

  final int maxBytes;
  final Set<String> allowedMimeTypes;

  /// Common document and image types.
  static const documentsAndImages = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'application/pdf',
    'text/plain',
    'text/csv',
    'application/zip',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };

  /// Detects the type from the file's leading bytes. The extension is trusted
  /// only for plain-text formats (which have no signature) and only when the
  /// content really looks like text; anything unrecognized is
  /// `application/octet-stream`, which no sane allow-list contains.
  static String detectMime(String filename, List<int> bytes) {
    final head = bytes.length > 16 ? bytes.sublist(0, 16) : bytes;
    final sniffed = lookupMimeType('', headerBytes: head);
    final byName = lookupMimeType(filename);
    if (sniffed != null) {
      if (sniffed == 'application/zip' &&
          byName != null &&
          byName.startsWith('application/vnd.openxmlformats-officedocument')) {
        return byName; // docx/xlsx/pptx are zip containers
      }
      return sniffed;
    }
    if (byName != null && byName.startsWith('text/') && _looksLikeText(bytes)) {
      return byName;
    }
    return 'application/octet-stream';
  }

  static bool _looksLikeText(List<int> bytes) {
    final sample = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
    if (sample.contains(0)) {
      return false;
    }
    try {
      utf8.decode(sample, allowMalformed: false);
      return true;
    } on FormatException {
      // A multi-byte character cut at the sample boundary is fine; anything else is binary.
      return bytes.length > 8192 &&
          sample.length == 8192 &&
          _validUtf8Prefix(sample);
    }
  }

  static bool _validUtf8Prefix(List<int> sample) {
    for (var cut = 0; cut < 4 && cut < sample.length; cut++) {
      try {
        utf8.decode(
          sample.sublist(0, sample.length - cut),
          allowMalformed: false,
        );
        return true;
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  /// Throws [UnsupportedFileException] / [FileTooLargeException] when the file
  /// is not acceptable. Returns the detected MIME type.
  String validate(String filename, List<int> bytes) {
    if (bytes.isEmpty) throw UnsupportedFileException('The file is empty.');
    if (bytes.length > maxBytes) throw FileTooLargeException(maxBytes);
    final mime = detectMime(filename, bytes);
    if (!allowedMimeTypes.contains(mime)) {
      throw UnsupportedFileException('Files of type "$mime" are not allowed.');
    }
    // A name that claims one binary type while the bytes are another is rejected (e.g. .png that is an .exe).
    final claimed = lookupMimeType(filename);
    if (claimed != null &&
        claimed != mime &&
        !claimed.startsWith('text/') &&
        mime != 'text/plain') {
      final officeZip =
          mime.startsWith('application/vnd.openxmlformats') && claimed == mime;
      if (!officeZip) {
        throw UnsupportedFileException(
          'The file extension does not match its content.',
        );
      }
    }
    return mime;
  }

  /// A display-safe name: no directories, no control characters or quotes,
  /// bounded length. Never use it as a storage path; generate one instead.
  static String safeName(String original) {
    var n = original
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f"<>|?*:]'), '_')
        .trim();
    if (n.isEmpty || n == '.' || n == '..') n = 'file';
    if (n.length > 120) {
      final dot = n.lastIndexOf('.');
      final ext = dot > 0 && n.length - dot <= 10 ? n.substring(dot) : '';
      n = n.substring(0, 120 - ext.length) + ext;
    }
    return n;
  }

  /// Lower-case extension (without dot) for generated storage names, or ''.
  static String extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || filename.length - dot > 10) return '';
    final e = filename.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]+$').hasMatch(e) ? e : '';
  }
}
