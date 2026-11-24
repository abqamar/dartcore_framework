## 0.1.0

- `Logger` and static `Log` facade with levels debug, info, warning, error and fatal.
- `ConsoleHandler` (pretty text or JSON lines), `FileHandler` (JSON lines) and `MemoryHandler` for tests; custom `LogHandler`s.
- `Redactor` masks sensitive context keys recursively, with configurable extra keys.
- Request-id correlation through zones when used with `dartcore_api`.

First release.
