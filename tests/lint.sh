#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SHELLCHECK_BIN=${SHELLCHECK_BIN:-$(command -v shellcheck 2>/dev/null || true)}
EXPECTED_VERSION=${SHELLCHECK_VERSION:-0.11.0}
EXPECTED_VERSION=${EXPECTED_VERSION#v}

if [[ -z "$SHELLCHECK_BIN" ]]; then
  printf 'ERROR: ShellCheck is required for static analysis.\n' >&2
  printf '       Install ShellCheck %s or set SHELLCHECK_BIN to its executable.\n' "$EXPECTED_VERSION" >&2
  exit 2
fi

if [[ ! -x "$SHELLCHECK_BIN" ]]; then
  printf 'ERROR: SHELLCHECK_BIN is not executable: %s\n' "$SHELLCHECK_BIN" >&2
  exit 2
fi

actual_version=$("$SHELLCHECK_BIN" --version | awk -F: '/^version:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
if [[ "$actual_version" != "$EXPECTED_VERSION" ]]; then
  printf 'ERROR: expected ShellCheck %s, found %s (%s)\n' "$EXPECTED_VERSION" "$actual_version" "$SHELLCHECK_BIN" >&2
  exit 2
fi

status=0
for file in "$ROOT_DIR/script/renombrador.sh" "$ROOT_DIR/tests/run.sh" "$ROOT_DIR/tests/lint.sh"; do
  printf 'ShellCheck %s\n' "${file#"$ROOT_DIR/"}"
  "$SHELLCHECK_BIN" --shell=bash --severity=warning "$file" || status=$?
done

exit "$status"
