#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

printf '== Shell syntax checks ==\n'
mapfile -d '' -t shell_files < <(
  find "$ROOT/scripts" "$ROOT/tests" -type f -name '*.sh' -print0 | sort -z
)
if ((${#shell_files[@]} == 0)); then
  echo 'ERROR: no shell scripts found under scripts/ or tests/' >&2
  exit 1
fi
for script in "${shell_files[@]}"; do
  printf 'bash -n %s\n' "${script#"$ROOT"/}"
  bash -n "$script"
done

printf '\n== Shell regression tests ==\n'
mapfile -d '' -t test_files < <(
  find "$ROOT/tests" -type f -name 'test-*.sh' -print0 | sort -z
)
if ((${#test_files[@]} == 0)); then
  echo 'ERROR: no tests/test-*.sh regression tests found' >&2
  exit 1
fi
for test_script in "${test_files[@]}"; do
  printf '\n-- %s --\n' "${test_script#"$ROOT"/}"
  bash "$test_script"
done

printf '\nPASS: syntax-checked %d shell scripts and ran %d regression tests.\n' \
  "${#shell_files[@]}" "${#test_files[@]}"
