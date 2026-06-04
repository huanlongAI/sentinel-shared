#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_passed_result() {
  local path="$1"
  local check_id="$2"
  local check_name="$3"
  cat > "$path" <<JSON
{"check_id":"${check_id}","check_name":"${check_name}","passed":true,"issues":[]}
JSON
}

write_escalate_llm_result() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "review_id": "llm-review",
  "check_name": "LLM Review",
  "provider": "heiyucode_claude_code",
  "status": "completed",
  "verdict": "ESCALATE",
  "reason": "requires governance owner verification",
  "passed": false,
  "escalate": true
}
JSON
}

write_comments() {
  local path="$1"
  local head_sha="$2"
  cat > "$path" <<JSON
[
  {
    "body": "### Sentinel owner-reviewed override\n\nsentinel-owner-reviewed-override: approved\nhead_sha: ${head_sha}\ndeterministic checks: PASS\nllm-review: ESCALATE\nfollow-up: https://github.com/huanlongAI/sentinel-shared/issues/100",
    "user": {"login": "gate-owner"},
    "author_association": "MEMBER",
    "html_url": "https://github.com/huanlongAI/hl-contracts/pull/92#issuecomment-1"
  }
]
JSON
}

write_comments_with_unstructured_head_mention() {
  local path="$1"
  local head_sha="$2"
  cat > "$path" <<JSON
[
  {
    "body": "### Sentinel owner-reviewed override\n\nsentinel-owner-reviewed-override: approved\ndeterministic checks: PASS\nllm-review: ESCALATE\nfollow-up: https://github.com/huanlongAI/sentinel-shared/issues/100\n\nDiscussion mentioned ${head_sha}, but not as a structured head field.",
    "user": {"login": "gate-owner"},
    "author_association": "MEMBER",
    "html_url": "https://github.com/huanlongAI/hl-contracts/pull/92#issuecomment-2"
  }
]
JSON
}

write_founder_ruling_comments() {
  local path="$1"
  cat > "$path" <<'JSON'
[
  {
    "body": "## Founder 裁决：#92 owner-reviewed governance evidence\n\n裁决项：Q-HLCONTRACTS-92-GOVERNANCE-EVIDENCE-001 = A\n\n结论：\n\n- 认可 #92 当前 deterministic checks（确定性检查）结果作为 owner-reviewed governance evidence（负责人已审治理证据）：\n  - D-1 / D-2 / D-3 / D-4 / D-5 / D-6 / D-10：PASS。\n- sentinel / 一致性检查 当前 FAILURE 的实际原因仅为 llm-review = ESCALATE。\n- 本裁决即为 GitHub SSOT（唯一事实源）中的 governance owner verification（治理负责人确认）。\n\n边界：\n\n- runtime_authorization = false\n- engineering_start = forbidden\n\n后续处理：\n\n- 不因 llm-review = ESCALATE 继续追加无实质治理差异的文档改动。",
    "user": {"login": "gate-owner"},
    "author_association": "OWNER",
    "created_at": "2026-06-03T09:34:15Z",
    "html_url": "https://github.com/huanlongAI/hl-contracts/pull/92#issuecomment-founder"
  }
]
JSON
}

test_owner_reviewed_override_accepts_exact_head_sha_owner_comment() {
  local tmp head_sha
  tmp="$(mktemp -d)"
  head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$tmp/repo/.sentinel/results"
  cat > "$tmp/repo/.sentinel/config.yaml" <<'YAML'
owner_reviewed_override_actors:
  - gate-owner
YAML
  write_passed_result "$tmp/repo/.sentinel/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/repo/.sentinel/results/llm-review.json"
  write_comments "$tmp/comments.json" "$head_sha"

  (
    cd "$tmp/repo"
    CONFIG_FILE=".sentinel/config.yaml" \
      RESULTS_DIR=".sentinel/results" \
      REQUIRED_DETERMINISTIC_RESULT_FILES="d1-changelog.json" \
      OWNER_REVIEWED_COMMENTS_FILE="$tmp/comments.json" \
      GITHUB_REPOSITORY="huanlongAI/hl-contracts" \
      PR_NUMBER="92" \
      HEAD_SHA="$head_sha" \
      "$ROOT_DIR/scripts/owner-reviewed-override.sh"
  )

  jq -e '
    .review_id == "owner-reviewed-override"
    and .passed == true
    and .status == "accepted"
    and .overrides_review_id == "llm-review"
    and .overrides_verdict == "ESCALATE"
    and .head_sha == "'"$head_sha"'"
    and .actor == "gate-owner"
  ' "$tmp/repo/.sentinel/results/owner-reviewed-override.json" >/dev/null ||
    fail "owner-reviewed override evidence was not accepted"
}

test_owner_reviewed_override_rejects_stale_head_sha_comment() {
  local tmp head_sha stale_sha
  tmp="$(mktemp -d)"
  head_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  stale_sha="cccccccccccccccccccccccccccccccccccccccc"
  mkdir -p "$tmp/repo/.sentinel/results"
  cat > "$tmp/repo/.sentinel/config.yaml" <<'YAML'
owner_reviewed_override_actors:
  - gate-owner
YAML
  write_passed_result "$tmp/repo/.sentinel/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/repo/.sentinel/results/llm-review.json"
  write_comments "$tmp/comments.json" "$stale_sha"

  (
    cd "$tmp/repo"
    CONFIG_FILE=".sentinel/config.yaml" \
      RESULTS_DIR=".sentinel/results" \
      REQUIRED_DETERMINISTIC_RESULT_FILES="d1-changelog.json" \
      OWNER_REVIEWED_COMMENTS_FILE="$tmp/comments.json" \
      GITHUB_REPOSITORY="huanlongAI/hl-contracts" \
      PR_NUMBER="92" \
      HEAD_SHA="$head_sha" \
      "$ROOT_DIR/scripts/owner-reviewed-override.sh"
  )

  [ ! -f "$tmp/repo/.sentinel/results/owner-reviewed-override.json" ] ||
    fail "stale owner-reviewed comment must not create override evidence"
}

test_owner_reviewed_override_requires_structured_head_sha_field() {
  local tmp head_sha
  tmp="$(mktemp -d)"
  head_sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  mkdir -p "$tmp/repo/.sentinel/results"
  cat > "$tmp/repo/.sentinel/config.yaml" <<'YAML'
owner_reviewed_override_actors:
  - gate-owner
YAML
  write_passed_result "$tmp/repo/.sentinel/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/repo/.sentinel/results/llm-review.json"
  write_comments_with_unstructured_head_mention "$tmp/comments.json" "$head_sha"

  (
    cd "$tmp/repo"
    CONFIG_FILE=".sentinel/config.yaml" \
      RESULTS_DIR=".sentinel/results" \
      REQUIRED_DETERMINISTIC_RESULT_FILES="d1-changelog.json" \
      OWNER_REVIEWED_COMMENTS_FILE="$tmp/comments.json" \
      GITHUB_REPOSITORY="huanlongAI/hl-contracts" \
      PR_NUMBER="92" \
      HEAD_SHA="$head_sha" \
      "$ROOT_DIR/scripts/owner-reviewed-override.sh"
  )

  [ ! -f "$tmp/repo/.sentinel/results/owner-reviewed-override.json" ] ||
    fail "owner-reviewed override must require structured head/head_sha evidence"
}

test_owner_reviewed_override_accepts_founder_ruling_after_head_commit() {
  local tmp head_sha
  tmp="$(mktemp -d)"
  head_sha="ffffffffffffffffffffffffffffffffffffffff"
  mkdir -p "$tmp/repo/.sentinel/results"
  cat > "$tmp/repo/.sentinel/config.yaml" <<'YAML'
owner_reviewed_override_actors:
  - gate-owner
YAML
  write_passed_result "$tmp/repo/.sentinel/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/repo/.sentinel/results/llm-review.json"
  write_founder_ruling_comments "$tmp/comments.json"

  (
    cd "$tmp/repo"
    CONFIG_FILE=".sentinel/config.yaml" \
      RESULTS_DIR=".sentinel/results" \
      REQUIRED_DETERMINISTIC_RESULT_FILES="d1-changelog.json" \
      OWNER_REVIEWED_COMMENTS_FILE="$tmp/comments.json" \
      GITHUB_REPOSITORY="huanlongAI/hl-contracts" \
      PR_NUMBER="92" \
      HEAD_SHA="$head_sha" \
      HEAD_COMMIT_EPOCH="1780477200" \
      "$ROOT_DIR/scripts/owner-reviewed-override.sh"
  )

  jq -e '
    .review_id == "owner-reviewed-override"
    and .passed == true
    and .status == "accepted"
    and .override_source == "founder_governance_ruling"
    and .overrides_review_id == "llm-review"
    and .overrides_verdict == "ESCALATE"
    and .head_sha == "'"$head_sha"'"
    and .actor == "gate-owner"
  ' "$tmp/repo/.sentinel/results/owner-reviewed-override.json" >/dev/null ||
    fail "founder governance ruling after head commit was not accepted"
}

test_owner_reviewed_override_rejects_founder_ruling_before_head_commit() {
  local tmp head_sha
  tmp="$(mktemp -d)"
  head_sha="9999999999999999999999999999999999999999"
  mkdir -p "$tmp/repo/.sentinel/results"
  cat > "$tmp/repo/.sentinel/config.yaml" <<'YAML'
owner_reviewed_override_actors:
  - gate-owner
YAML
  write_passed_result "$tmp/repo/.sentinel/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/repo/.sentinel/results/llm-review.json"
  write_founder_ruling_comments "$tmp/comments.json"

  (
    cd "$tmp/repo"
    CONFIG_FILE=".sentinel/config.yaml" \
      RESULTS_DIR=".sentinel/results" \
      REQUIRED_DETERMINISTIC_RESULT_FILES="d1-changelog.json" \
      OWNER_REVIEWED_COMMENTS_FILE="$tmp/comments.json" \
      GITHUB_REPOSITORY="huanlongAI/hl-contracts" \
      PR_NUMBER="92" \
      HEAD_SHA="$head_sha" \
      HEAD_COMMIT_EPOCH="1780480800" \
      "$ROOT_DIR/scripts/owner-reviewed-override.sh"
  )

  [ ! -f "$tmp/repo/.sentinel/results/owner-reviewed-override.json" ] ||
    fail "founder governance ruling before head commit must not create override evidence"
}

test_aggregate_treats_llm_escalate_with_owner_override_as_owner_reviewed_pass() {
  local tmp output code
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/results"
  write_passed_result "$tmp/results/d1-changelog.json" "D-1" "CHANGELOG"
  write_escalate_llm_result "$tmp/results/llm-review.json"
  cat > "$tmp/results/owner-reviewed-override.json" <<'JSON'
{
  "review_id": "owner-reviewed-override",
  "check_name": "Owner Reviewed Override",
  "passed": true,
  "status": "accepted",
  "overrides_review_id": "llm-review",
  "overrides_verdict": "ESCALATE",
  "head_sha": "dddddddddddddddddddddddddddddddddddddddd",
  "actor": "gate-owner",
  "comment_url": "https://github.com/huanlongAI/hl-contracts/pull/92#issuecomment-1"
}
JSON

  set +e
  output=$(
    RESULTS_DIR="$tmp/results" \
      REQUIRED_RESULT_FILES="d1-changelog.json llm-review.json" \
      GITHUB_OUTPUT="$tmp/github-output" \
      "$ROOT_DIR/scripts/aggregate.sh" 2>&1
  )
  code=$?
  set -e

  [ "$code" -eq 0 ] || fail "owner-reviewed LLM ESCALATE should pass aggregate, output: $output"
  jq -e '
    .verdict.overall_passed == true
    and .verdict.gate_result == "OWNER_REVIEWED_PASS"
    and .verdict.failed == 0
    and .verdict.owner_reviewed_overrides == 1
    and .owner_reviewed_override.overrides_review_id == "llm-review"
  ' "$tmp/results/aggregate.json" >/dev/null ||
    fail "aggregate did not record OWNER_REVIEWED_PASS verdict"
  grep -q '^gate_result=OWNER_REVIEWED_PASS$' "$tmp/github-output" ||
    fail "aggregate did not publish gate_result output"
}

test_owner_reviewed_workflow_shape() {
  local workflow
  workflow="$(cat "$ROOT_DIR/.github/workflows/consistency-sentinel.yml")"
  [[ "$workflow" == *"owner-reviewed-override.sh"* ]] ||
    fail "workflow must run owner-reviewed override before aggregate"
  [[ "$workflow" == *"gate_result"* ]] ||
    fail "workflow must consume aggregate gate_result output"
}

test_owner_reviewed_override_accepts_exact_head_sha_owner_comment
test_owner_reviewed_override_rejects_stale_head_sha_comment
test_owner_reviewed_override_requires_structured_head_sha_field
test_owner_reviewed_override_accepts_founder_ruling_after_head_commit
test_owner_reviewed_override_rejects_founder_ruling_before_head_commit
test_aggregate_treats_llm_escalate_with_owner_override_as_owner_reviewed_pass
test_owner_reviewed_workflow_shape

echo "owner-reviewed override tests passed"
