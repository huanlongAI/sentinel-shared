#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/self-test.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if [ ! -f "$file" ]; then
    fail "Expected file to exist: $file"
  fi
  if ! grep -Fq "$needle" "$file"; then
    fail "Expected $file to contain: $needle"
  fi
}

assert_file_contains "$WORKFLOW" "pull_request:"
assert_file_contains "$WORKFLOW" "bash tests/test-llm-review-provider-router.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-policy-file.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-d7-d8.sh"
assert_file_contains "$WORKFLOW" "bash -n scripts/*.sh tests/*.sh .sentinel/checks/*.sh"
assert_file_contains "$WORKFLOW" "YAML.load_file"

echo "ci workflow tests passed"
