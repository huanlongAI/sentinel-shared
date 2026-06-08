#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "Expected output to contain: $needle"
  fi
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

append_large_anchor_files() {
  local dir="$1"
  local count="${2:-48}"
  local size_bytes="${3:-45000}"
  local i anchor_path

  mkdir -p "$dir/anchors"
  cat >> "$dir/.sentinel/config.yaml" <<'YAML'
anchor_files:
YAML

  for i in $(seq 1 "$count"); do
    anchor_path="$dir/anchors/context-${i}.md"
    {
      printf 'anchor-%s\n' "$i"
      head -c "$size_bytes" /dev/zero | tr '\0' 'x'
      printf '\n'
    } > "$anchor_path"
    printf '  context_%s: "anchors/context-%s.md"\n' "$i" "$i" >> "$dir/.sentinel/config.yaml"
  done
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

printf '%s\n' "$*" > "$FAKE_CALL_DIR/curl.args"

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
  escalate)
    write_response 200 '{"content":[{"type":"text","text":"{\"verdict\":\"ESCALATE\",\"checks\":{\"GPC-003\":{\"verdict\":\"ESCALATE\",\"confidence\":0.80,\"reason\":\"needs owner review\"}},\"summary\":\"escalate\"}"}]}'
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
  non_json_text)
    write_response 200 '{"content":[{"type":"text","text":"No blocking findings."}]}'
    ;;
  http_500)
    write_response 500 '{"error":{"message":"upstream unavailable"}}'
    ;;
  http_524_then_pass)
    if [ "$count" -eq 1 ]; then
      write_response 524 'error code: 524'
    else
      write_response 200 '{"content":[{"type":"text","text":"{\"verdict\":\"PASS\",\"checks\":{\"GPC-003\":{\"verdict\":\"PASS\",\"confidence\":0.96,\"reason\":\"ok\"}},\"summary\":\"ok\"}"}]}'
    fi
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

write_recording_jq() {
  local jq_path="$1"
  local real_jq
  real_jq="$(command -v jq)"
  cat > "$jq_path" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\$FAKE_CALL_DIR/jq.args"
exec "$real_jq" "\$@"
SH
  chmod +x "$jq_path"
}

test_heiyucode_provider_uses_messages_api() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  write_fake_heiyucode_curl "$fake_bin/curl"
  write_recording_jq "$fake_bin/jq"

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
  grep -q -- '--data-binary @' "$calls/curl.args" || fail "HeiyuCode request body should be sent via file-backed --data-binary"
  grep -q -- '--rawfile system' "$calls/jq.args" || fail "HeiyuCode request body should load system prompt from file"
  grep -q -- '--rawfile user' "$calls/jq.args" || fail "HeiyuCode request body should load user prompt from file"
  if grep -q -- '--arg system ' "$calls/jq.args"; then
    fail "HeiyuCode request body should not pass system prompt via --arg"
  fi
  if grep -q -- '--arg user ' "$calls/jq.args"; then
    fail "HeiyuCode request body should not pass user prompt via --arg"
  fi
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .http_status == "200"
    and .auth_header_kind == "authorization_bearer"
    and .exit_code == 0
    and .duration_seconds >= 0
    and .stdout_bytes > 0
    and .stderr_bytes == 0
    and .attempts == 1
    and .base_url_configured == true
    and .api_url_configured == true
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
{"error":{"message":"provider unavailable"}}
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

  [ "$code" -ne 0 ] || fail "Anthropic API errors must fail closed"
  assert_contains "$output" "fail closed"
  jq -e '.provider == "anthropic" and .status == "error" and .passed == false and .escalate == true' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Anthropic API error result must fail"
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

  [ "$code" -ne 0 ] || fail "Empty provider text must fail closed"
  assert_contains "$output" "fail closed"
  jq -e '.provider == "anthropic" and .status == "error" and .passed == false and .escalate == true' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Empty response result must fail"
}

test_heiyucode_provider_hard_fails_explicit_escalate_verdict() {
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
      FAKE_CURL_MODE="escalate" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )
  status="$?"
  set -e

  [ "$status" -ne 0 ] || fail "Explicit ESCALATE verdict should hard fail"
  jq -e '.provider == "heiyucode_claude_code" and .verdict == "ESCALATE" and .passed == false' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Explicit ESCALATE result mismatch"
}

test_heiyucode_provider_timeout_fails_closed_without_waiting_for_job_timeout() {
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

  [ "$status" -ne 0 ] || fail "Timeout should fail closed"
  [ "$elapsed" -lt 6 ] || fail "Timeout path waited too long: ${elapsed}s"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and (.reason | test("timeout"))
    and .passed == false
    and .escalate == true
    and .exit_code == 124
    and .duration_seconds >= 1
    and .base_url_configured == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Timeout provider diagnostics mismatch"
}

test_heiyucode_provider_nonzero_exit_fails_closed_with_diagnostics() {
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

  [ "$status" -ne 0 ] || fail "Provider non-zero exit should fail closed"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .model == "claude-heiyu-test"
    and .status == "error"
    and .error_type == "provider_error"
    and .passed == false
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

test_heiyucode_provider_empty_output_fails_closed_with_diagnostics() {
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

  [ "$status" -ne 0 ] || fail "Empty provider response should fail closed"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "No text in response"
    and .passed == false
    and .escalate == true
    and .exit_code == 0
    and .stdout_bytes == 0
    and .stderr_bytes == 0
    and .stderr_tail == ""
    and .response_tail == ""
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Empty output diagnostics mismatch"
}

test_heiyucode_provider_non_json_review_fails_closed_with_valid_result_json() {
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
      FAKE_CURL_MODE="non_json_text" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )
  status="$?"
  set -e

  [ "$status" -ne 0 ] || fail "Non-JSON review text should fail closed"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "Could not extract LLM review JSON"
    and .passed == false
    and .escalate == true
    and .http_status == "200"
    and .stdout_bytes > 0
    and (.response_tail | contains("No blocking findings."))
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Non-JSON review diagnostics mismatch"
}

test_heiyucode_provider_http_error_fails_closed_with_response_tail() {
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

  [ "$status" -ne 0 ] || fail "HTTP provider error should fail closed"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .status == "error"
    and .error_type == "provider_error"
    and .reason == "HeiyuCode Messages API HTTP 500"
    and .passed == false
    and .escalate == true
    and .http_status == "500"
    and .attempts == 2
    and (.response_tail | contains("upstream unavailable"))
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "HTTP error diagnostics mismatch"
}

test_heiyucode_provider_retries_retryable_524_once() {
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
      FAKE_CURL_MODE="http_524_then_pass" \
      SENTINEL_LLM_PROVIDER="heiyucode" \
      HEIYUCODE_AUTH_TOKEN="heiyucode-test-token" \
      HEIYUCODE_BASE_URL="https://www.heiyucode.com" \
      HEIYUCODE_MODEL="claude-heiyu-test" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  [ "$(cat "$calls/curl.count")" = "2" ] || fail "Retryable 524 should be retried exactly once"
  jq -e '
    .provider == "heiyucode_claude_code"
    and .transport == "messages-api"
    and .http_status == "200"
    and .attempts == 2
    and .passed == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Retryable 524 retry result mismatch"
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
    and .exit_code == 0
    and .duration_seconds >= 0
    and .stdout_bytes > 0
    and .stderr_bytes == 0
    and .attempts == 2
    and .base_url_configured == true
    and .api_url_configured == true
    and .passed == true
  ' "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "x-api-key fallback result mismatch"
}

test_request_body_uses_file_backed_payload_for_anthropic() {
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
  write_recording_jq "$fake_bin/jq"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="anthropic" \
      ANTHROPIC_API_KEY="anthropic-test-key" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q -- '--data-binary @' "$calls/curl.args" || fail "Anthropic request body should be sent via file-backed --data-binary"
  grep -q -- '--rawfile system' "$calls/jq.args" || fail "Anthropic request body should load system prompt from file"
  grep -q -- '--rawfile user' "$calls/jq.args" || fail "Anthropic request body should load user prompt from file"
  if grep -q -- '--arg system ' "$calls/jq.args"; then
    fail "Anthropic request body should not pass system prompt via --arg"
  fi
  if grep -q -- '--arg user ' "$calls/jq.args"; then
    fail "Anthropic request body should not pass user prompt via --arg"
  fi
}

test_large_prompt_uses_file_backed_payload_without_arg_list_overflow() {
  local tmp fake_bin calls
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"
  append_large_anchor_files "$tmp/repo"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$FAKE_CALL_DIR/curl.args"
cat <<'JSON'
{"content":[{"text":"{\"verdict\":\"PASS\",\"checks\":{\"GPC-003\":{\"verdict\":\"PASS\",\"confidence\":0.95,\"reason\":\"ok\"}},\"summary\":\"ok\"}"}]}
JSON
SH
  chmod +x "$fake_bin/curl"
  write_recording_jq "$fake_bin/jq"

  (
    cd "$tmp/repo"
    PATH="$fake_bin:$PATH" \
      FAKE_CALL_DIR="$calls" \
      SENTINEL_LLM_PROVIDER="anthropic" \
      ANTHROPIC_API_KEY="anthropic-test-key" \
      "$ROOT_DIR/scripts/llm-review.sh"
  )

  grep -q -- '--data-binary @' "$calls/curl.args" || fail "Large prompt request body should be sent via file-backed --data-binary"
  grep -q -- '--rawfile system' "$calls/jq.args" || fail "Large prompt request body should load system prompt from file"
  grep -q -- '--rawfile user' "$calls/jq.args" || fail "Large prompt request body should load user prompt from file"
  jq -e '.provider == "anthropic" and .passed == true' \
    "$tmp/repo/.sentinel/results/llm-review.json" >/dev/null || fail "Large prompt result metadata mismatch"
}

test_large_rulings_anchor_extracts_referenced_ruling_sections() {
  local tmp fake_bin calls prompt
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat >> "$tmp/repo/.sentinel/config.yaml" <<'YAML'
anchor_files:
  rulings: "RULINGS.md"
YAML
  {
    printf 'RULINGS HEADER\n'
    head -c 62000 /dev/zero | tr '\0' 'x'
    printf '\n\n### R-0123｜NODE-D Test Ruling\n\n'
    printf 'R-0123 source excerpt required for GPC-003.\n'
    printf 'This exact R-0123 line must be loaded from the large RULINGS.md anchor.\n\n'
    printf '### R-0124｜Unreferenced Ruling\n\n'
    printf 'This unreferenced R-0124 line should not be loaded.\n'
  } > "$tmp/repo/RULINGS.md"
  git -C "$tmp/repo" add .sentinel/config.yaml RULINGS.md
  git -C "$tmp/repo" commit -q -m "add large rulings"

  cat > "$tmp/repo/contract.json" <<'JSON'
{"ref":"RULINGS.md#R-0123","status":"request_only"}
JSON
  git -C "$tmp/repo" add contract.json
  git -C "$tmp/repo" commit -q -m "reference ruling"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-binary)
      body="${2#@}"
      cp "$body" "$FAKE_CALL_DIR/request.json"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
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

  prompt="$(jq -r '.messages[0].content' "$calls/request.json")"
  assert_contains "$prompt" "R-0123 source excerpt required for GPC-003."
  assert_contains "$prompt" "This exact R-0123 line must be loaded from the large RULINGS.md anchor."
  if [[ "$prompt" == *"This unreferenced R-0124 line should not be loaded."* ]]; then
    fail "Unreferenced RULINGS section should not be loaded into the LLM context pack"
  fi
}

test_large_rulings_anchor_extracts_three_digit_ruling_sections() {
  local tmp fake_bin calls prompt
  tmp="$(mktemp -d)"
  fake_bin="$tmp/bin"
  calls="$tmp/calls"
  mkdir -p "$fake_bin" "$calls"
  make_repo "$tmp/repo"

  cat >> "$tmp/repo/.sentinel/config.yaml" <<'YAML'
anchor_files:
  governance_rulings: "governance/RULINGS.md"
YAML
  mkdir -p "$tmp/repo/governance"
  {
    printf 'RULINGS HEADER\n'
    head -c 62000 /dev/zero | tr '\0' 'x'
    printf '\n\n## R-077 biz.sales.order PM Cap-Spec candidate-only Draft PR authorization readback\n\n'
    printf 'R-077 source excerpt required for GPC-003.\n'
    printf 'This exact R-077 line must be loaded from the large governance/RULINGS.md anchor.\n\n'
    printf '## R-078 Unreferenced Ruling\n\n'
    printf 'This unreferenced R-078 line should not be loaded.\n'
  } > "$tmp/repo/governance/RULINGS.md"
  git -C "$tmp/repo" add .sentinel/config.yaml governance/RULINGS.md
  git -C "$tmp/repo" commit -q -m "add large governance rulings"

  cat > "$tmp/repo/traceability.yaml" <<'YAML'
source_rulings:
  - governance/RULINGS.md#R-077
YAML
  git -C "$tmp/repo" add traceability.yaml
  git -C "$tmp/repo" commit -q -m "reference R-077"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-binary)
      body="${2#@}"
      cp "$body" "$FAKE_CALL_DIR/request.json"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
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

  prompt="$(jq -r '.messages[0].content' "$calls/request.json")"
  assert_contains "$prompt" "R-077 source excerpt required for GPC-003."
  assert_contains "$prompt" "This exact R-077 line must be loaded from the large governance/RULINGS.md anchor."
  if [[ "$prompt" == *"This unreferenced R-078 line should not be loaded."* ]]; then
    fail "Unreferenced three-digit RULINGS section should not be loaded into the LLM context pack"
  fi
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

  [ "$code" -ne 0 ] || fail "Aggregator must fail when llm-review.json failed"
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

  [ "$code" -ne 0 ] || fail "Aggregator must fail when a required result file is missing"
  jq -e '.verdict.failed == 1 and (.results[] | select(.check_id == "D-MISSING" and .passed == false and (.issues[] | contains("d2-terminology.json"))))' \
    "$tmp/results/aggregate.json" >/dev/null || fail "Aggregator must materialize missing required result failure"
}

test_workflow_requires_llm_result_when_llm_enabled() {
  local workflow
  workflow="$(cat "$ROOT_DIR/.github/workflows/consistency-sentinel.yml")"
  assert_contains "$workflow" "REQUIRED_RESULT_FILES="
  assert_contains "$workflow" "llm-review.json"
  assert_contains "$workflow" "inputs.skip_llm"
}

test_anthropic_provider_uses_messages_api
test_request_body_uses_file_backed_payload_for_anthropic
test_large_prompt_uses_file_backed_payload_without_arg_list_overflow
test_large_rulings_anchor_extracts_referenced_ruling_sections
test_large_rulings_anchor_extracts_three_digit_ruling_sections
test_heiyucode_provider_uses_messages_api
test_heiyucode_provider_hard_fails_explicit_fail_verdict
test_anthropic_api_error_fails_closed
test_anthropic_empty_text_fails_closed
test_heiyucode_provider_hard_fails_explicit_escalate_verdict
test_heiyucode_provider_timeout_fails_closed_without_waiting_for_job_timeout
test_heiyucode_provider_nonzero_exit_fails_closed_with_diagnostics
test_heiyucode_provider_empty_output_fails_closed_with_diagnostics
test_heiyucode_provider_non_json_review_fails_closed_with_valid_result_json
test_heiyucode_provider_http_error_fails_closed_with_response_tail
test_heiyucode_provider_retries_retryable_524_once
test_heiyucode_provider_retries_x_api_key_after_bearer_auth_failure
test_aggregate_includes_llm_review_failure
test_aggregate_fails_closed_when_required_result_is_missing
test_workflow_requires_llm_result_when_llm_enabled

echo "llm-review provider router tests passed"
