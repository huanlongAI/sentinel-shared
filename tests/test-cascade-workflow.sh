#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/cascade-verify.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "Expected workflow to contain: $needle"
  fi
}

if [ ! -f "$WORKFLOW" ]; then
  fail "cascade verification workflow is missing"
fi

workflow="$(cat "$WORKFLOW")"

assert_contains "$workflow" "::error::Some dispatches failed:"
assert_contains "$workflow" 'exit 1'
assert_contains "$workflow" 'DISPATCH_FAILED="${{ needs.fan-out.outputs.failed }}"'
assert_contains "$workflow" 'if [ -n "$DISPATCH_FAILED" ] || [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then'
assert_contains "$workflow" '::error::Cascade verification incomplete or failed:'
assert_contains "$workflow" "always() && (steps.results.outputs.fail != '0' || steps.results.outputs.skip != '0' || needs.fan-out.outputs.failed != '')"
assert_contains "$workflow" "if: always()"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"

echo "cascade workflow fail-closed shape test passed"
