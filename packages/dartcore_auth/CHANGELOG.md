## 0.1.0

- `AuthService`: Argon2id password hashing, HS256 JWT access tokens, opaque refresh tokens with rotation and replay detection.
- Route middleware for authentication, roles and permissions (with wildcards); credentials from Bearer header, API key header or cookie.
- Long-lived API tokens with abilities, single-use password reset tokens and server-side cookie sessions (`SessionManager`).
- In-memory stores plus `DatabaseAuthStores` for PostgreSQL, MySQL and SQLite.
- Weak or placeholder JWT secrets are rejected at construction.

First release.
