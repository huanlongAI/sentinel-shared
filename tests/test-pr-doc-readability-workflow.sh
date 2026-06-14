#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENTINEL_WORKFLOW="$ROOT_DIR/.github/workflows/consistency-sentinel.yml"
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

[ -f "$ROOT_DIR/scripts/check-pr-doc-readability.py" ] || fail "D-12 script is missing"

assert_file_contains "$SENTINEL_WORKFLOW" "D-12: PR 文档中文可读性检查"
assert_file_contains "$SENTINEL_WORKFLOW" "check-pr-doc-readability.py"
assert_file_contains "$SENTINEL_WORKFLOW" "d12-pr-doc-readability.json"
assert_file_contains "$SENTINEL_WORKFLOW" "GITHUB_STEP_SUMMARY"
assert_file_not_contains "$SENTINEL_WORKFLOW" "paths:"

assert_file_contains "$MATRIX" "GPC-009"
assert_file_contains "$MATRIX" "PR 文档中文可读性"
assert_file_contains "$MATRIX" "precheck_id: D-12"
assert_file_contains "$MATRIX" "D-12:"
assert_file_contains "$MATRIX" "check-pr-doc-readability.py"
assert_file_contains "$MATRIX" "check_ids: [GPC-009]"

assert_file_contains "$SELF_TEST" "python3 tests/test-pr-doc-readability.py"
assert_file_contains "$SELF_TEST" "bash tests/test-pr-doc-readability-workflow.sh"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$SENTINEL_WORKFLOW"

tmp="$(mktemp -d)"
mkdir -p "$tmp/results"
cat > "$tmp/results/d12-pr-doc-readability.json" <<'JSON'
{
  "check_id": "D-12",
  "check_name": "PR Doc Chinese Readability",
  "passed": false,
  "violations": [
    {
      "code": "doc_missing_chinese",
      "path": "docs/example.md",
      "message": "docs/example.md has no Chinese prose characters"
    }
  ]
}
JSON

set +e
aggregate_output=$(RESULTS_DIR="$tmp/results" REQUIRED_RESULT_FILES="d12-pr-doc-readability.json" "$ROOT_DIR/scripts/aggregate.sh" 2>&1)
aggregate_code=$?
set -e

[ "$aggregate_code" -eq 1 ] || fail "aggregate should fail when D-12 has blocking violations: $aggregate_output"
grep -Fq "docs/example.md has no Chinese prose characters" "$tmp/results/sentinel-report.md" \
  || fail "aggregate report must render D-12 object violation messages"
jq -e '.issues[] | contains("docs/example.md has no Chinese prose characters")' "$tmp/results/aggregate.json" >/dev/null \
  || fail "aggregate issues must include D-12 object violation messages"

echo "pr doc readability workflow test passed"
