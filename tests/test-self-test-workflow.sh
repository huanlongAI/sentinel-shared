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
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$file must contain: $needle"
  fi
}

if [ ! -f "$WORKFLOW" ]; then
  fail "Sentinel shared self-test workflow is missing"
fi

assert_file_contains "$WORKFLOW" "name: Sentinel Shared Self Test"
assert_file_contains "$WORKFLOW" "pull_request:"
assert_file_contains "$WORKFLOW" "push:"
assert_file_contains "$WORKFLOW" "branches: [main]"
assert_file_contains "$WORKFLOW" "AGENTS.md"
assert_file_contains "$WORKFLOW" "CLAUDE.md"
assert_file_contains "$WORKFLOW" "name: Sentinel Shared Gate"
assert_file_contains "$WORKFLOW" "actions/checkout@v5"
assert_file_contains "$WORKFLOW" "bash tests/test-policy-file.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-d7-d8.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-caller-sync-workflow.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-caller-targets.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-caller-token-write-probe-workflow.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-dashboard-workflow.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-cascade-workflow.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-llm-review-provider-router.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-llm-message-client.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-aux-llm-workflows.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-owner-reviewed-override.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-review-gate-audit.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-agent-governance.sh"
assert_file_contains "$WORKFLOW" "bash tests/test-self-test-workflow.sh"
assert_file_contains "$WORKFLOW" "bash -n scripts/*.sh tests/*.sh .sentinel/checks/*.sh"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"

echo "self-test workflow shape test passed"
