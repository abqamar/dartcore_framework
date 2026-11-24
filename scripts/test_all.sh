#!/usr/bin/env bash
# Runs analyzer + every package's tests + example tests + (if databases are up)
# the integration suite. Start databases with:
#   docker compose -f integration_tests/docker-compose.yml up -d postgres mysql
set -euo pipefail
cd "$(dirname "$0")/.."

dart pub get
dart format --output=none --set-exit-if-changed packages examples integration_tests benchmarks
dart analyze --fatal-infos

for d in packages/* examples/complete_application examples/tasks_api integration_tests; do
  # Driver packages (postgres, mysql) are covered by integration_tests.
  if compgen -G "$d/test/*_test.dart" > /dev/null; then
    printf '\n=== %s\n' "$d"
    (cd "$d" && dart test -r expanded 2>&1 | tail -n 3)
  fi
done
