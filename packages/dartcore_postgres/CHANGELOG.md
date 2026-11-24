## 0.1.0

- PostgreSQL adapter for `dartcore_db`, registered with `registerPostgres()`.
- Pooled connections with TLS modes (disable, require, verifyFull) and `application_name` option.
- Transactions and savepoints; `RETURNING` support for inserts.
- Database errors mapped to typed `dartcore_core` exceptions without leaking driver internals.
- Verified against PostgreSQL 16 by the repository's shared contract suite.

First release.
