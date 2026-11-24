## 0.1.0

- `Cache` static facade and `CacheRepository` instances: put, get, delete, remember (cache-aside).
- `MemoryCacheStore` with TTL expiry and LRU eviction (`maxEntries`).
- Namespaces that can be cleared independently.
- `remember` de-duplicates concurrent loader runs and never caches `null` or errors.
- `CacheStore` interface as the extension point for other backends.

First release.
