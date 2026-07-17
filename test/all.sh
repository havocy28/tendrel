#!/usr/bin/env bash
# Single entrypoint for tendrel's tests. Runs the deterministic tier by default; pass --contracts
# to also run the expensive, headless, rate-based contract tier (needs API access, not for CI).
# Run this before pushing: a push to main is a release to every installed project.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

run_contracts=0
for arg in "$@"; do
  case "$arg" in
    --contracts) run_contracts=1 ;;
    -h|--help) echo "usage: test/all.sh [--contracts]"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; echo "usage: test/all.sh [--contracts]" >&2; exit 2 ;;
  esac
done

# Deterministic tier: fast, no model, safe for CI.
deterministic=(checks.sh graph-lint.sh report-verbosity.sh backwards-compat.sh)

failed=()
run(){
  local name="$1"
  echo "=== $name ==="
  if bash "$DIR/$name"; then
    echo ">>> $name: PASS"
  else
    echo ">>> $name: FAIL"
    failed+=("$name")
  fi
  echo
}

for t in "${deterministic[@]}"; do run "$t"; done

# Contract tier: opt-in. Headless model runs, rate-based, needs API access - never in CI.
if [ "$run_contracts" -eq 1 ]; then
  echo "=== contract tier (headless, needs API access) ==="
  run background-integration.sh
  run reconcile-autonomy-integration.sh
  run next-integration.sh
fi

echo "==================================="
if [ "${#failed[@]}" -eq 0 ]; then
  echo "test/all.sh: ALL PASSED"
  exit 0
else
  echo "test/all.sh: FAILED -> ${failed[*]}"
  exit 1
fi
