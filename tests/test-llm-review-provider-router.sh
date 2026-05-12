#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir/.sentinel/results" "$dir/.sentinel/prompts"
  cat > "$dir/.sentinel/config.yaml" <<'YAML'
llm:
  model: "claude-test-model"
  max_output_tokens: 1024
  confidence_threshold: 0.7
  checks:
    - "GPC-003"
YAML
  cat > "$dir/.sentinel/prompts/sentinel-system.md" <<'EOF'
System prompt for test.
EOF
  git -C "$dir" init -q
  git -C "$dir" config user.email "sentinel-test@example.invalid"
  git -C "$dir" config user.name "Sentinel Test"
  printf 'before\n' > "$dir/sample.txt"
  git -C "$dir" add sample.txt .sentinel/config.yaml .sentinel/prompts/sentinel-system.md
  git -C "$dir" commit -q -m "initial"
  printf 'after\n' > "$dir/sample.txt"
  git -C "$dir" add sample.txt
  git -C "$dir" commit -q -m "change"
}

test_anthropic_provider_uses_messages_api() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_CALL_DIR/curl.args"
cat <<'JSON'
{"content":[{"text":"{\"verdict\":\"PASS\",\"checks\":{\"GPC-003\":{\"verdict\":\"PASS\",\"confidence\":0.95,\"reason\":\"ok\"}},\"summary\":\"ok\"}"}]}
JSON
SH
  chmod +x "$fake_bin/curl"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="anthropic" \
      ANTHROPIC_API_KEY="anthropic-test-key" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q "https://api.anthropic.com/v1/messages" "$calls/curl.args" || fail "Anthropic API URL not used"
  jq -e '.provider == "anthropic" and .passed == true and .model == "claude-test-model"' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Anthropic result metadata mismatch"
}

test_heiyucode_provider_uses_claude_code_client() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${ANTHROPIC_BASE_URL:-}" > "$FAKE_CALL_DIR/claude.base_url"
printf '%s\n' "${ANTHROPIC_AUTH_TOKEN:-}" > "$FAKE_CALL_DIR/claude.token"
printf '%s\n' "$*" > "$FAKE_CALL_DIR/claude.args"
cat <<'JSON'
{"verdict":"PASS","checks":{"GPC-003":{"verdict":"PASS","confidence":0.96,"reason":"ok"}},"summary":"ok"}
JSON
SH
  chmod +x "$fake_bin/claude"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q "https://www.heiyucode.com" "$calls/claude.base_url" || fail "HeiyuCode base URL not used"
  grep -q "heiyucode-test-token" "$calls/claude.token" || fail "HeiyuCode token not used"
  grep -q -- "--model claude-heiyu-test" "$calls/claude.args" || fail "HeiyuCode model not passed to Claude client"
  jq -e '.provider == "heiyucode_claude_code" and .passed == true and .model == "claude-heiyu-test"' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "HeiyuCode result metadata mismatch"
}

test_anthropic_api_error_fails_closed() {
  local tmp fake_bin calls output code
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_CALL_DIR/curl.args"
cat <<'JSON'
{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}
JSON
SH
  chmod +x "$fake_bin/curl"

  set +e
  output=$(
    cd "$tmp/repo" && \
      PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="anthropic" \
      ANTHROPIC_API_KEY="anthropic-test-key" \
      "$ROOT_DIR/scripts/llm-review.sh" 2>&1
  )
  code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "$output" >&2
    fail "Anthropic API errors must fail closed"
  fi
  jq -e '.provider == "anthropic" and .status == "error" and .passed == false and .escalate == true' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Anthropic API error result must be failing"
}

test_anthropic_empty_text_fails_closed() {
  local tmp fake_bin calls output code
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_CALL_DIR/curl.args"
cat <<'JSON'
{"content":[{"text":""}]}
JSON
SH
  chmod +x "$fake_bin/curl"

  set +e
  output=$(
    cd "$tmp/repo" && \
      PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="anthropic" \
      ANTHROPIC_API_KEY="anthropic-test-key" \
      "$ROOT_DIR/scripts/llm-review.sh" 2>&1
  )
  code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "$output" >&2
    fail "Empty provider text must fail closed"
  fi
  jq -e '.provider == "anthropic" and .status == "error" and .passed == false and .escalate == true' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Empty response result must be failing"
}

test_aggregate_includes_llm_review_failure() {
  local tmp output code
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/results"
  cat > "$tmp/results/d1-changelog.json" <<'JSON'
{"check_id":"D-1","check_name":"CHANGELOG","passed":true,"issues":[]}
JSON
  cat > "$tmp/results/llm-review.json" <<'JSON'
{"review_id":"llm-review","check_name":"LLM Review","provider":"anthropic","status":"error","reason":"API error","passed":false,"escalate":true}
JSON

  set +e
  output=$(RESULTS_DIR="$tmp/results" REQUIRED_RESULT_FILES="d1-changelog.json" "$ROOT_DIR/scripts/aggregate.sh" 2>&1)
  code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "$output" >&2
    fail "Aggregator must fail when llm-review.json failed"
  fi
  jq -e '.verdict.total_checks == 2 and .verdict.failed == 1 and (.results[] | select(.review_id == "llm-review" and .passed == false))' \
    "$tmp/results/aggregate.json" >/dev/null || fail "Aggregator must include failed llm-review result"
}

test_aggregate_fails_closed_when_required_result_is_missing() {
  local tmp output code
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/results"
  cat > "$tmp/results/d1-changelog.json" <<'JSON'
{"check_id":"D-1","check_name":"CHANGELOG","passed":true,"issues":[]}
JSON

  set +e
  output=$(RESULTS_DIR="$tmp/results" REQUIRED_RESULT_FILES="d1-changelog.json d2-terminology.json" "$ROOT_DIR/scripts/aggregate.sh" 2>&1)
  code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "$output" >&2
    fail "Aggregator must fail when a required result file is missing"
  fi
  jq -e '.verdict.failed == 1 and (.results[] | select(.check_id == "D-MISSING" and .passed == false and (.issues[] | contains("d2-terminology.json"))))' \
    "$tmp/results/aggregate.json" >/dev/null || fail "Aggregator must materialize missing required result failure"
}

test_anthropic_provider_uses_messages_api
test_heiyucode_provider_uses_claude_code_client
test_anthropic_api_error_fails_closed
test_anthropic_empty_text_fails_closed
test_aggregate_includes_llm_review_failure
test_aggregate_fails_closed_when_required_result_is_missing

echo "llm-review provider router tests passed"
