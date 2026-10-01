#!/usr/bin/env bash
# Run all tests — no network or credentials needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
total_pass=0
total_fail=0
suites=0

for test in "$SCRIPT_DIR"/test-*.sh; do
  suites=$((suites + 1))
  echo ""
  echo "--- $(basename "$test") ---"
  if bash "$test"; then
    echo "  Suite PASSED"
  else
    echo "  Suite FAILED"
    total_fail=$((total_fail + 1))
  fi
done

echo ""
echo "==========================================="
echo "$suites suites run. $total_fail failed."
echo "==========================================="

[ "$total_fail" -eq 0 ] && exit 0 || exit 1
