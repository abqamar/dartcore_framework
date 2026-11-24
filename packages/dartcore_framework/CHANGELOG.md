## 0.1.0

- Umbrella library: one import re-exports `dartcore_core`, `dartcore_logging`, `dartcore_validation`, `dartcore_db` and `dartcore_api`.
- `DartCore` application class: an `App` configured from `APP_*` keys that disconnects its `DatabaseManager` on shutdown.
- `databaseExistenceChecker` to back the `unique` and `exists` validation rules with a database.
- Database adapters, migrations, ORM, auth, cache, storage and dashboard are separate, optional packages.

First release.
