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

write_fake_heiyucode_curl() {
  local curl_path="$1"
  cat > "$curl_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -H)
      printf '%s\n' "$2" >> "$FAKE_CALL_DIR/curl.headers"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

count_file="$FAKE_CALL_DIR/curl.count"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count="$((count + 1))"
printf '%s\n' "$count" > "$count_file"

write_response() {
  local status="$1"
  local body="$2"
  printf '%s' "$body" > "$out"
  printf 'http_status=%s\ntime_total=0.01\nsize_download=%s\n' "$status" "$(wc -c < "$out" | tr -d ' ')"
}

case "${FAKE_CURL_MODE}" in
  pass)
    write_response 200 '{"content":[{"type":"text","text":"{\"verdict\":\"PASS\",\"checks\":{\"GPC-003\":{\"verdict\":\"PASS\",\"confidence\":0.96,\"reason\":\"ok\"}},\"summary\":\"ok\"}"}]}'
    ;;
  fail)
    write_response 200 '{"content":[{"type":"text","text":"{\"verdict\":\"FAIL\",\"checks\":{\"GPC-003\":{\"verdict\":\"FAIL\",\"confidence\":0.98,\"reason\":\"policy conflict\"}},\"summary\":\"fail\"}"}]}'
    ;;
  sleep)
    sleep 2
    ;;
  nonzero)
    echo "provider boom ${HEIYUCODE_AUTH_TOKEN:-}" >&2
    exit 17
    ;;
  empty)
    write_response 200 ''
    ;;
  http_500)
    write_response 500 '{"error":{"message":"upstream unavailable"}}'
    ;;
  auth_fallback)
    if [ "$count" -eq 1 ]; then
      write_response 401 '{"code":"INVALID_API_KEY","message":"bad auth header"}'
    else
      write_response 200 '{"content":[{"type":"text","text":"{\"verdict\":\"PASS\",\"checks\":{\"GPC-003\":{\"verdict\":\"PASS\",\"confidence\":0.96,\"reason\":\"ok\"}},\"summary\":\"ok\"}"}]}'
    fi
    ;;
  *)
    echo "unknown FAKE_CURL_MODE=${FAKE_CURL_MODE}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$curl_path"
}

test_heiyucode_provider_uses_messages_api() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  write_fake_heiyucode_curl "$fake_bin/curl"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="pass" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q "Authorization: Bearer heiyucode-test-token" "$calls/curl.headers" || fail "HeiyuCode bearer token not used"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .http_status == "200"
    and .auth_header_kind == "authorization_bearer"
    and .passed == true
    and .model == "claude-heiyu-test"
  ' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "HeiyuCode result metadata mismatch"
}

test_heiyucode_provider_hard_fails_explicit_fail_verdict() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  write_fake_heiyucode_curl "$fake_bin/curl"

  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="fail" \
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

  write_fake_heiyucode_curl "$fake_bin/curl"

  started="$(date +%s)"
  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="sleep" \
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
    and .transport == "messages-api"
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

  write_fake_heiyucode_curl "$fake_bin/curl"

  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="nonzero" \
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
    and .transport == "messages-api"
    and .model == "claude-heiyu-test"
    and .status == "error"
    and .error_type == "provider_error"
    and .passed == true
    and .escalate == true
    and .exit_code == 17
    and .stdout_bytes == 0
    and .stderr_bytes > 0
    and (.stderr_tail | contains("provider boom"))
    and (.stderr_tail | contains("[redacted]"))
    and .base_url_configured == true
    and .api_url_configured == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Non-zero provider diagnostics mismatch"
}

test_heiyucode_provider_empty_output_escalates_with_diagnostics() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  write_fake_heiyucode_curl "$fake_bin/curl"

  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="empty" \
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
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "No text in response"
    and .passed == true
    and .escalate == true
    and .exit_code == 0
    and .stdout_bytes == 0
    and .stderr_bytes == 0
    and .stderr_tail == ""
    and .response_tail == ""
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Empty output diagnostics mismatch"
}

test_heiyucode_provider_http_error_escalates_with_response_tail() {
  local tmp fake_bin calls status
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"
  write_fake_heiyucode_curl "$fake_bin/curl"

  set +e
  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="http_500" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )
  status="$?"
  set -e

  [ "$status" -eq 0 ] || fail "HTTP provider error should be non-blocking ESCALATE"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "HeiyuCode Messages API HTTP 500"
    and .passed == true
    and .escalate == true
    and .http_status == "500"
    and (.response_tail | contains("upstream unavailable"))
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "HTTP error diagnostics mismatch"
}

test_heiyucode_provider_retries_x_api_key_after_bearer_auth_failure() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"
  write_fake_heiyucode_curl "$fake_bin/curl"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      FAKE_CURL_MODE="auth_fallback" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q "Authorization: Bearer heiyucode-test-token" "$calls/curl.headers" || fail "Bearer auth was not attempted"
  grep -q "x-api-key: heiyucode-test-token" "$calls/curl.headers" || fail "x-api-key fallback was not attempted"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .http_status == "200"
    and .auth_header_kind == "x-api-key"
    and .passed == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "x-api-key fallback result mismatch"
}

test_anthropic_provider_uses_messages_api
test_heiyucode_provider_uses_messages_api
test_heiyucode_provider_hard_fails_explicit_fail_verdict
test_heiyucode_provider_timeout_escalates_without_waiting_for_job_timeout
test_heiyucode_provider_nonzero_exit_escalates_with_diagnostics
test_heiyucode_provider_empty_output_escalates_with_diagnostics
test_heiyucode_provider_http_error_escalates_with_response_tail
test_heiyucode_provider_retries_x_api_key_after_bearer_auth_failure

echo "llm-review provider router tests passed"
