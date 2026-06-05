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
assert_contains "$workflow" 'CASCADE_WAIT_TIMEOUT_SECONDS="${CASCADE_WAIT_TIMEOUT_SECONDS:-900}"'
assert_contains "$workflow" 'CASCADE_POLL_INTERVAL_SECONDS="${CASCADE_POLL_INTERVAL_SECONDS:-20}"'
assert_contains "$workflow" 'deadline=$((SECONDS + CASCADE_WAIT_TIMEOUT_SECONDS))'
assert_contains "$workflow" 'while true; do'
assert_contains "$workflow" 'GH_TOKEN: ${{ secrets.CASCADE_RESULTS_TOKEN || secrets.CASCADE_TOKEN }}'
assert_contains "$workflow" 'API_ERROR=0'
assert_contains "$workflow" 'curl -sS -o "$RUN_RESPONSE_FILE" -w "%{http_code}"'
assert_contains "$workflow" 'actions/runs HTTP ${RUN_HTTP_STATUS}'
assert_contains "$workflow" 'if [ "$API_ERROR" -gt 0 ] || [ "$SKIP" -eq 0 ] || [ "$SECONDS" -ge "$deadline" ]; then'
assert_contains "$workflow" 'if [ -n "$DISPATCH_FAILED" ] || [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then'
assert_contains "$workflow" '::error::Cascade verification incomplete or failed:'
assert_contains "$workflow" 'ISSUE_HTTP_STATUS=$(curl -sS -o /tmp/cascade-issue-response.json -w "%{http_code}"'
assert_contains "$workflow" 'if [ "$ISSUE_HTTP_STATUS" != "201" ]; then'
assert_contains "$workflow" '::error::Cascade failure issue creation failed: HTTP ${ISSUE_HTTP_STATUS}'
assert_contains "$workflow" 'GH_TOKEN: ${{ github.token }}'
assert_contains "$workflow" 'jq -e '\''.labels[]? | select(.name == "cascade-failure")'\'' /tmp/cascade-issue-response.json'
assert_contains "$workflow" '::error::Cascade failure issue was created without cascade-failure label'
assert_contains "$workflow" "always() && (steps.results.outputs.fail != '0' || steps.results.outputs.skip != '0' || needs.fan-out.outputs.failed != '')"
assert_contains "$workflow" "if: always()"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"

echo "cascade workflow fail-closed shape test passed"
