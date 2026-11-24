# tasks_api

The API built in the [DartCore tutorial](../../docs/tutorial.md): users register and sign in with JWT tokens, and manage
their own **tasks**. Every task query is scoped to the signed-in user, so another user's task looks like a missing one (404).

```
POST /auth/register  /auth/login  /auth/refresh  /auth/logout      GET /auth/me
GET|POST /api/tasks        GET|PUT|DELETE /api/tasks/:id             (filters: ?status= ?q= ?sort= ?page= ?limit=)
GET /health
```

## Run it

Without a database server (SQLite):

```bash
cp .env.example .env
# in .env: DB_DRIVER=sqlite, DB_DATABASE=storage/database.sqlite, and a JWT_SECRET (openssl rand -base64 48)
dart run bin/console.dart migrate
dart run bin/server.dart
```

With PostgreSQL: create a database and user, set `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` in `.env`, then the same
two commands. The tutorial explains each step, including deployment.

## Test it

```bash
dart test        # 6 tests on an in-memory SQLite database; no server needed
```

Note: `dartcore build` cannot compile SQLite projects to a standalone binary (native build hook), but this example registers
both adapters so it can run and be tested either way. A real PostgreSQL-only project does not have that limitation.
