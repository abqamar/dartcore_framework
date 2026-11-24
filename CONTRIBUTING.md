# Contributing

## Setup

```bash
dart pub get                                                         # whole workspace (Dart >= 3.10)
docker compose -f integration_tests/docker-compose.yml up -d postgres mysql
./scripts/test_all.sh                                                # must pass before a PR
```

## Rules of the road

* **Tests prove features.** A feature isn't done because it compiles. Add unit tests, and for anything touching SQL add the
  case to `integration_tests/test/contract.dart` so it runs on every engine.
* **No fake implementations, no silent emulation.** If an engine can't do something, throw a typed exception that says so and
  record it in [DATABASE_COMPATIBILITY.md](DATABASE_COMPATIBILITY.md).
* **Security by default.** Values are bound, identifiers validated, secrets never logged, errors never leak internals. See
  [SECURITY.md](SECURITY.md); a change that weakens a default needs a stated reason.
* **Public API stays small and driver-independent.** Keep implementation in `lib/src/`; don't export Shelf or driver types.
* **No new dependencies** without a reason in the PR (maintenance, license, API stability were checked for the existing ones).
* Format with `dart format`, keep `dart analyze --fatal-infos` clean, follow Effective Dart.
* Update docs and [CHANGELOG.md](CHANGELOG.md) with the change.

## Adding an adapter

See [docs/custom-adapters.md](docs/custom-adapters.md): implement `DriverConnection`, register it, and run the contract suite.

## Releasing

Packages are published to pub.dev **manually by the owner**; never publish or push tags on someone else's behalf.
Published versions are permanent (they can be retracted or discontinued, not deleted), so review the dry run first.

Checklist:

1. The MIT `LICENSE` exists at the repository root and a copy sits in each package directory (pub.dev requires it per package; keep them identical).
2. Every package has `version`, `repository`, `issue_tracker`, a 60-180 character `description`, a `README.md`, a
   `CHANGELOG.md` entry for the version and an `example/`. No package has `publish_to: none` (the workspace root,
   `examples/`, `benchmarks/` and `integration_tests/` keep it).
3. Internal dependencies use `^x.y.z` constraints that match the versions being published. Bump versions consistently.
4. `./scripts/test_all.sh` passes, including the PostgreSQL and MySQL integration suites.
5. Dry run each package in dependency order and fix every warning:
   `dartcore_core`, `dartcore_logging`, `dartcore_validation`, `dartcore_db`, `dartcore_api`, `dartcore_sqlite`,
   `dartcore_postgres`, `dartcore_mysql`, `dartcore_migrations`, `dartcore_orm`, `dartcore_auth`, `dartcore_cache`,
   `dartcore_storage`, `dartcore_dashboard`, `dartcore_framework`, `dartcore_cli`:
   `cd packages/<name> && dart pub publish --dry-run`.
   A dependent's dry run only resolves once its dependencies are live on pub.dev, so publish in that order.
6. Tag the release (`v0.1.0`). Then verify in an empty directory that `dart pub global activate dartcore_cli` and
   `dartcore create demo --database sqlite` work **without** `--path`.
