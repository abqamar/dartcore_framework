## 0.1.0

- `StorageDisk` interface and `Storage` registry for named disks.
- `LocalStorage`: path validation (no absolute paths, `..` or symlink escapes), atomic writes and streaming size limits.
- `FileRules`: size limit, MIME allow-list, content sniffing, extension/content mismatch detection and `safeName`.
- Typed exceptions with HTTP-style status codes for not found, too large, invalid path and unsupported file.

First release.
