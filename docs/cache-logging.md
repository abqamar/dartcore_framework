# Caching and logging

## Cache (`dartcore_cache`)

```dart
await Cache.put('users', users, ttl: const Duration(minutes: 10));     // value must be JSON-encodable
final cached = await Cache.get<List<dynamic>>('users');
await Cache.delete('users');

final stats = await Cache.remember('stats', const Duration(minutes: 1), () => computeStats());   // cache-aside
final users = Cache.namespace('users');                                // keys prefixed "users:"
await users.put('1', row);   await users.clear();                      // clears only that namespace
```

* Values are stored as JSON strings: you get snapshots, and every backend behaves identically.
* `remember` shares one loader run between concurrent callers (no stampede), does not cache `null`, and never caches errors.
* `MemoryCacheStore(maxEntries: 10000)` has TTL expiry and LRU eviction; it is per process.
* **Not implemented: Redis.** Implement `CacheStore` (`read`, `write`, `remove`, `removeByPrefix`) to add one.
* Do not cache secrets or personal data by default; keep TTLs short and prefer caching derived data.
* Instance use: `CacheRepository(MemoryCacheStore())`; swap the default with `Cache.use(...)`.

## Logging (`dartcore_logging`)

```dart
Log.info('Server started');
Log.error('Database connection failed', error: e, stackTrace: st);
Log.info('login', context: {'email': email, 'password': pw});          // password → [REDACTED]

Log.use(Logger(
  level: LogLevel.parse(Config.get('LOG_LEVEL'), LogLevel.info),
  handlers: [ConsoleHandler(json: true), FileHandler('storage/logs/app.log')],
));
```

* Levels: `debug info warning error fatal`. JSON-lines or pretty console output; `FileHandler` appends JSON lines;
  `MemoryHandler` for tests. Errors go to stderr.
* Context keys matching `password`, `secret`, `token`, `authorization`, `api_key`, `cookie`, `credential`, `private_key`,
  `card_number`, `cvv` (case-insensitive, recursive, add more via `Redactor(extraKeys: [...])`) are masked.
* Records inside a request carry its request id automatically (zone-based).
* Do not log request bodies wholesale; DartCore's `LoggerMiddleware` logs only method, path, status, duration and IP.
* File handler has no rotation: use logrotate/your platform's log shipping.
