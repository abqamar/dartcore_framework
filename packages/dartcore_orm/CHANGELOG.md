## 0.1.0

- `Model` base class with explicit mapping (`toMap` / `fillFromMap`), `Casts` helpers and `ModelRepository` / `ModelQuery`.
- CRUD, pagination, automatic `created_at` / `updated_at` timestamps and soft deletes (`withTrashed`, `onlyTrashed`, `restore`, `forceDelete`).
- Mass-assignment protection (`fillable`), hidden attributes and validation through `rules` (uses `dartcore_validation`).
- Lifecycle hooks: saving, creating, created, updating, updated, saved, deleting, deleted.
- Relations: `HasMany`, `HasOne`, `BelongsTo`, `BelongsToMany` with eager loading that avoids N+1 queries.

First release.
