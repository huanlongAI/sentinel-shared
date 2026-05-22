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

test_heiyucode_provider_hard_fails_explicit_fail_verdict() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"verdict":"FAIL","checks":{"GPC-003":{"verdict":"FAIL","confidence":0.98,"reason":"policy conflict"}},"summary":"fail"}
JSON
SH
  chmod +x "$fake_bin/claude"

  set +e
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
  status="$?"
  set -e

  [ "$status" -ne 0 ] || fail "Explicit FAIL verdict should hard fail"
  jq -e '.provider == "heiyucode_claude_code" and .verdict == "FAIL" and .passed == false' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Explicit FAIL result mismatch"
}

test_heiyucode_provider_timeout_escalates_without_waiting_for_job_timeout() {
  local tmp fake_bin calls status started elapsed
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sleep 2
cat <<'JSON'
{"verdict":"PASS","checks":{"GPC-003":{"verdict":"PASS","confidence":0.96,"reason":"ok"}},"summary":"ok"}
JSON
SH
  chmod +x "$fake_bin/claude"

  started="$(date +%s)"
  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      HEIYUCODE_CLIENT_TIMEOUT_SECONDS="1" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )
  status="$?"
  set -e
  elapsed="$(( $(date +%s) - started ))"

  [ "$status" -eq 0 ] || fail "Timeout should be non-blocking ESCALATE"
  [ "$elapsed" -lt 6 ] || fail "Timeout path waited too long: ${elapsed}s"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .status == "error"
    and .error_type == "provider_error"
    and (.reason | test("timeout"))
    and .passed == true
    and .escalate == true
    and .exit_code == 124
    and .duration_seconds >= 1
    and .base_url_configured == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Timeout provider diagnostics mismatch"
}

test_heiyucode_provider_nonzero_exit_escalates_with_diagnostics() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "provider boom" >&2
exit 17
SH
  chmod +x "$fake_bin/claude"

  set +e
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
  status="$?"
  set -e

  [ "$status" -eq 0 ] || fail "Provider non-zero exit should be non-blocking ESCALATE"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .model == "claude-heiyu-test"
    and .status == "error"
    and .error_type == "provider_error"
    and .passed == true
    and .escalate == true
    and .exit_code == 17
    and .stdout_bytes == 0
    and .stderr_bytes > 0
    and (.stderr_tail | contains("provider boom"))
    and .base_url_configured == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Non-zero provider diagnostics mismatch"
}

test_heiyucode_provider_empty_output_escalates_with_diagnostics() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
  chmod +x "$fake_bin/claude"

  set +e
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
  status="$?"
  set -e

  [ "$status" -eq 0 ] || fail "Empty provider response should be non-blocking ESCALATE"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "No text in response"
    and .passed == true
    and .escalate == true
    and .exit_code == 0
    and .stdout_bytes == 0
    and .stderr_bytes == 0
    and .stderr_tail == ""
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Empty output diagnostics mismatch"
}

test_anthropic_provider_uses_messages_api
test_heiyucode_provider_uses_claude_code_client
test_heiyucode_provider_hard_fails_explicit_fail_verdict
test_heiyucode_provider_timeout_escalates_without_waiting_for_job_timeout
test_heiyucode_provider_nonzero_exit_escalates_with_diagnostics
test_heiyucode_provider_empty_output_escalates_with_diagnostics

echo "llm-review provider router tests passed"
