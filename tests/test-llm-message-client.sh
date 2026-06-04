#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT_DIR/scripts/llm-message-client.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains_file() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$file must contain: $needle"
  fi
}

assert_not_contains_file() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file must not contain secret: $needle"
  fi
}

write_prompts() {
  local dir="$1"
  printf 'system prompt\n' > "$dir/system.txt"
  printf 'user prompt\n' > "$dir/user.txt"
}

write_fake_curl() {
  local curl_path="$1"
  cat > "$curl_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
printf '%s\n' "$*" >> "$FAKE_CALL_DIR/curl.args"

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
    -X|--max-time|-w|--data-binary)
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$out" ]; then
  echo "missing -o output path" >&2
  exit 2
fi

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
  heiyucode_pass)
    [[ "$url" == *"heiyucode.test"* ]] || { echo "unexpected URL: $url" >&2; exit 3; }
    write_response 200 '{"content":[{"type":"text","text":"heiyucode-ok"}]}'
    ;;
  anthropic_pass)
    [[ "$url" == *"api.anthropic.com"* ]] || { echo "unexpected URL: $url" >&2; exit 3; }
    write_response 200 '{"content":[{"text":"anthropic-ok"}]}'
    ;;
  heiyucode_auth_fallback)
    [[ "$url" == *"heiyucode.test"* ]] || { echo "unexpected URL: $url" >&2; exit 3; }
    if [ "$count" -eq 1 ]; then
      write_response 401 '{"error":{"message":"bad bearer token"}}'
    else
      write_response 200 '{"content":[{"type":"text","text":"heiyucode-x-api-key-ok"}]}'
    fi
    ;;
  heiyucode_500_then_anthropic)
    if [[ "$url" == *"heiyucode.test"* ]]; then
      write_response 500 '{"error":{"message":"upstream unavailable"}}'
    elif [[ "$url" == *"api.anthropic.com"* ]]; then
      write_response 200 '{"content":[{"text":"anthropic-fallback-ok"}]}'
    else
      echo "unexpected URL: $url" >&2
      exit 3
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

run_client() {
  local tmp="$1"
  shift
  (
    cd "$tmp"
    PATH="$tmp/bin:$PATH" \
      LLM_SYSTEM_PROMPT_FILE="$tmp/system.txt" \
      LLM_USER_PROMPT_FILE="$tmp/user.txt" \
      LLM_OUTPUT_FILE="$tmp/out.txt" \
      LLM_MODEL="claude-test-model" \
      LLM_MAX_TOKENS="256" \
      HEIYUCODE_BASE_URL="https://heiyucode.test" \
      HEIYUCODE_MODEL="heiyu-test-model" \
      "$@" \
      "$CLIENT"
  ) > "$tmp/stdout.txt" 2> "$tmp/stderr.txt"
}

make_tmp() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/calls"
  write_prompts "$tmp"
  write_fake_curl "$tmp/bin/curl"
  printf '%s\n' "$tmp"
}

test_auto_prefers_heiyucode_when_token_is_configured() {
  local tmp
  tmp="$(make_tmp)"

  [ -x "$CLIENT" ] || fail "shared LLM client must be executable"

  FAKE_CALL_DIR="$tmp/calls" \
    FAKE_CURL_MODE="heiyucode_pass" \
    SENTINEL_LLM_PROVIDER="auto" \
    HEIYUCODE_AUTH_TOKEN="heiyu-secret" \
    ANTHROPIC_API_KEY="anthropic-secret" \
    run_client "$tmp" env

  assert_contains_file "$tmp/out.txt" "heiyucode-ok"
  assert_contains_file "$tmp/calls/curl.args" "https://heiyucode.test/v1/messages"
  assert_contains_file "$tmp/calls/curl.headers" "Authorization: Bearer heiyu-secret"
  assert_not_contains_file "$tmp/stdout.txt" "heiyu-secret"
  assert_not_contains_file "$tmp/stderr.txt" "heiyu-secret"
}

test_auto_uses_anthropic_when_heiyucode_token_is_missing() {
  local tmp
  tmp="$(make_tmp)"

  FAKE_CALL_DIR="$tmp/calls" \
    FAKE_CURL_MODE="anthropic_pass" \
    SENTINEL_LLM_PROVIDER="auto" \
    ANTHROPIC_API_KEY="anthropic-secret" \
    run_client "$tmp" env

  assert_contains_file "$tmp/out.txt" "anthropic-ok"
  assert_contains_file "$tmp/calls/curl.args" "https://api.anthropic.com/v1/messages"
  assert_contains_file "$tmp/calls/curl.headers" "x-api-key: anthropic-secret"
  assert_not_contains_file "$tmp/stdout.txt" "anthropic-secret"
  assert_not_contains_file "$tmp/stderr.txt" "anthropic-secret"
}

test_heiyucode_retries_with_x_api_key_after_auth_error() {
  local tmp
  tmp="$(make_tmp)"

  FAKE_CALL_DIR="$tmp/calls" \
    FAKE_CURL_MODE="heiyucode_auth_fallback" \
    SENTINEL_LLM_PROVIDER="heiyucode" \
    HEIYUCODE_AUTH_TOKEN="heiyu-secret" \
    run_client "$tmp" env

  assert_contains_file "$tmp/out.txt" "heiyucode-x-api-key-ok"
  assert_contains_file "$tmp/calls/curl.headers" "Authorization: Bearer heiyu-secret"
  assert_contains_file "$tmp/calls/curl.headers" "x-api-key: heiyu-secret"
  [ "$(cat "$tmp/calls/curl.count")" = "2" ] || fail "HeiyuCode auth fallback must make two attempts"
}

test_auto_falls_back_to_anthropic_after_heiyucode_provider_error() {
  local tmp
  tmp="$(make_tmp)"

  FAKE_CALL_DIR="$tmp/calls" \
    FAKE_CURL_MODE="heiyucode_500_then_anthropic" \
    SENTINEL_LLM_PROVIDER="auto" \
    HEIYUCODE_AUTH_TOKEN="heiyu-secret" \
    ANTHROPIC_API_KEY="anthropic-secret" \
    run_client "$tmp" env

  assert_contains_file "$tmp/out.txt" "anthropic-fallback-ok"
  assert_contains_file "$tmp/calls/curl.args" "https://heiyucode.test/v1/messages"
  assert_contains_file "$tmp/calls/curl.args" "https://api.anthropic.com/v1/messages"
  [ "$(cat "$tmp/calls/curl.count")" = "2" ] || fail "auto fallback must call HeiyuCode then Anthropic"
}

test_auto_prefers_heiyucode_when_token_is_configured
test_auto_uses_anthropic_when_heiyucode_token_is_missing
test_heiyucode_retries_with_x_api_key_after_auth_error
test_auto_falls_back_to_anthropic_after_heiyucode_provider_error

echo "llm message client tests passed"
