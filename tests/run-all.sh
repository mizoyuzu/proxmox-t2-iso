#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shopt -s nullglob
tests=("$ROOT"/tests/test-*.sh)
if (( ${#tests[@]} == 0 )); then
  echo 'ERROR: no tests/test-*.sh scripts found.' >&2
  exit 1
fi

for test_script in "${tests[@]}"; do
  printf '\n=== %s ===\n' "${test_script#"$ROOT"/}"
  bash "$test_script"
done

printf '\nPASS: all %d test scripts completed.\n' "${#tests[@]}"
