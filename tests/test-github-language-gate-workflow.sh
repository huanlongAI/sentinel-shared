#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/github-language-gate.yml"
MATRIX="$ROOT_DIR/matrix/sentinel-matrix.yaml"
SELF_TEST="$ROOT_DIR/.github/workflows/self-test.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -Fq -- "$needle" "$file" || fail "$file must contain: $needle"
}

assert_file_not_contains() {
  local file="$1" needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file must not contain: $needle"
  fi
}

[ -f "$WORKFLOW" ] || fail "GitHub language gate reusable workflow is missing"

assert_file_contains "$WORKFLOW" "name: GitHub Language Gate"
assert_file_contains "$WORKFLOW" "workflow_call:"
assert_file_contains "$WORKFLOW" "enforcement_mode:"
assert_file_contains "$WORKFLOW" "default: audit"
assert_file_contains "$WORKFLOW" "report_comment:"
assert_file_contains "$WORKFLOW" "default: false"
assert_file_contains "$WORKFLOW" "repository: huanlongAI/sentinel-shared"
assert_file_contains "$WORKFLOW" "path: .sentinel-shared"
assert_file_contains "$WORKFLOW" "scripts/check-github-language-gate.py"
assert_file_contains "$WORKFLOW" "--enforcement-mode"
assert_file_contains "$WORKFLOW" "--github-output"
assert_file_contains "$WORKFLOW" "中文门禁未通过"
assert_file_contains "$WORKFLOW" "gh issue comment"
assert_file_contains "$WORKFLOW" "inputs.report_comment"
assert_file_not_contains "$WORKFLOW" "permissions:"

assert_file_contains "$MATRIX" "GPC-008"
assert_file_contains "$MATRIX" "GitHub 对外回复语言门禁"
assert_file_contains "$MATRIX" "precheck_id: D-11"
assert_file_contains "$MATRIX" "D-11:"
assert_file_contains "$MATRIX" "check-github-language-gate.py"
assert_file_contains "$MATRIX" "check_ids: [GPC-008]"

assert_file_contains "$SELF_TEST" "python3 tests/test-github-language-gate.py"
assert_file_contains "$SELF_TEST" "bash tests/test-github-language-gate-workflow.sh"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"

echo "github language gate workflow test passed"
