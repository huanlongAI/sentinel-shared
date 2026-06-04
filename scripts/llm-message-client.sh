#!/usr/bin/env bash
set -euo pipefail

# Shared Claude-compatible Messages API client for auxiliary Sentinel workflows.
# Inputs:
#   LLM_SYSTEM_PROMPT_FILE, LLM_USER_PROMPT_FILE, LLM_OUTPUT_FILE
# Optional:
#   SENTINEL_LLM_PROVIDER=auto|heiyucode|anthropic
#   LLM_MODEL, LLM_MAX_TOKENS
#   HEIYUCODE_AUTH_TOKEN, HEIYUCODE_API_KEY, HEIYUCODE_BASE_URL, HEIYUCODE_API_URL, HEIYUCODE_MODEL
#   ANTHROPIC_API_KEY

SYSTEM_PROMPT_FILE="${LLM_SYSTEM_PROMPT_FILE:-}"
USER_PROMPT_FILE="${LLM_USER_PROMPT_FILE:-}"
OUTPUT_FILE="${LLM_OUTPUT_FILE:-}"
REQUESTED_PROVIDER="${SENTINEL_LLM_PROVIDER:-${LLM_PROVIDER:-auto}}"
LLM_MODEL="${LLM_MODEL:-claude-sonnet-4-6}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-4096}"
HEIYUCODE_BASE_URL="${HEIYUCODE_BASE_URL:-https://www.heiyucode.com}"
HEIYUCODE_API_URL="${HEIYUCODE_API_URL:-${HEIYUCODE_BASE_URL%/}/v1/messages}"
HEIYUCODE_MODEL="${HEIYUCODE_MODEL:-$LLM_MODEL}"
HEIYUCODE_TOKEN="${HEIYUCODE_AUTH_TOKEN:-${HEIYUCODE_API_KEY:-}}"
HEIYUCODE_CLIENT_TIMEOUT_SECONDS="${HEIYUCODE_CLIENT_TIMEOUT_SECONDS:-120}"
ANTHROPIC_API_URL="https://api.anthropic.com/v1/messages"

CLIENT_TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$CLIENT_TMP_DIR"
}

trap cleanup EXIT

fail() {
  echo "::error::$*" >&2
  exit 1
}

if [ -z "$SYSTEM_PROMPT_FILE" ] || [ ! -f "$SYSTEM_PROMPT_FILE" ]; then
  fail "LLM_SYSTEM_PROMPT_FILE must point to an existing file"
fi

if [ -z "$USER_PROMPT_FILE" ] || [ ! -f "$USER_PROMPT_FILE" ]; then
  fail "LLM_USER_PROMPT_FILE must point to an existing file"
fi

if [ -z "$OUTPUT_FILE" ]; then
  fail "LLM_OUTPUT_FILE must be set"
fi

if ! [[ "$LLM_MAX_TOKENS" =~ ^[0-9]+$ ]] || [ "$LLM_MAX_TOKENS" -lt 1 ]; then
  LLM_MAX_TOKENS=4096
fi

if ! [[ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" -lt 1 ]; then
  HEIYUCODE_CLIENT_TIMEOUT_SECONDS=120
fi

redact_string() {
  local text="$1"
  local secret
  for secret in "${ANTHROPIC_API_KEY:-}" "$HEIYUCODE_TOKEN"; do
    if [ -n "$secret" ]; then
      text="${text//$secret/[redacted]}"
    fi
  done
  printf '%s' "$text"
}

json_error_message() {
  local response_file="$1"
  jq -r '.error.message // .message // empty' "$response_file" 2>/dev/null || true
}

extract_http_status() {
  local meta_file="$1"
  awk -F= '/^http_status=/{print $2; exit}' "$meta_file" 2>/dev/null || true
}

file_size_bytes() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -c < "$file" 2>/dev/null | tr -d ' ' || echo 0
  else
    echo 0
  fi
}

build_request_body() {
  local model="$1"
  local request_body_file="$2"
  jq -n \
    --arg model "$model" \
    --argjson max_tokens "$LLM_MAX_TOKENS" \
    --rawfile system "$SYSTEM_PROMPT_FILE" \
    --rawfile user "$USER_PROMPT_FILE" \
    '{model:$model,max_tokens:$max_tokens,system:$system,messages:[{role:"user",content:$user}]}' \
    > "$request_body_file"
}

extract_text_response() {
  local response_file="$1"
  local stderr_file="$2"
  jq -r '[.content[]? | select(type == "object") | .text // empty] | join("\n\n")' \
    "$response_file" 2>"$stderr_file" || true
}

curl_messages_api() {
  local api_url="$1"
  local auth_header="$2"
  local request_body_file="$3"
  local response_file="$4"
  local stderr_file="$5"
  local meta_file="$6"

  set +e
  curl -sS --max-time "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" \
    -o "$response_file" \
    -w "http_status=%{http_code}\ntime_total=%{time_total}\nsize_download=%{size_download}\n" \
    -X POST "$api_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -H "$auth_header" \
    --data-binary "@${request_body_file}" \
    > "$meta_file" 2> "$stderr_file"
  local status="$?"
  set -e

  return "$status"
}

LAST_PROVIDER="n/a"
LAST_MODEL="n/a"
LAST_REASON="n/a"
LAST_MESSAGE=""
LAST_HTTP_STATUS="n/a"
LAST_EXIT_CODE="0"
LAST_AUTH_HEADER_KIND="n/a"
LAST_ATTEMPTS="0"
LAST_STDOUT_BYTES="0"
LAST_STDERR_BYTES="0"

diagnostic_line() {
  local level="$1"
  local safe_message
  safe_message="$(redact_string "${LAST_MESSAGE:-}")"
  echo "::${level}::LLM provider request failed (provider=${LAST_PROVIDER} model=${LAST_MODEL} reason=${LAST_REASON} http_status=${LAST_HTTP_STATUS} exit_code=${LAST_EXIT_CODE} auth_header_kind=${LAST_AUTH_HEADER_KIND} attempts=${LAST_ATTEMPTS} stdout_bytes=${LAST_STDOUT_BYTES} stderr_bytes=${LAST_STDERR_BYTES} message=${safe_message:-n/a})" >&2
}

try_anthropic() {
  local text_output_file="$1"
  local request_body_file="$CLIENT_TMP_DIR/anthropic-request.json"
  local response_file="$CLIENT_TMP_DIR/anthropic-response.json"
  local stderr_file="$CLIENT_TMP_DIR/anthropic-stderr.txt"
  local meta_file="$CLIENT_TMP_DIR/anthropic-meta.txt"
  local text

  LAST_PROVIDER="anthropic"
  LAST_MODEL="$LLM_MODEL"
  LAST_REASON="n/a"
  LAST_MESSAGE=""
  LAST_HTTP_STATUS="n/a"
  LAST_EXIT_CODE="0"
  LAST_AUTH_HEADER_KIND="x-api-key"
  LAST_ATTEMPTS="1"
  LAST_STDOUT_BYTES="0"
  LAST_STDERR_BYTES="0"

  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    LAST_REASON="credentials_missing"
    LAST_MESSAGE="ANTHROPIC_API_KEY not configured"
    return 1
  fi

  build_request_body "$LLM_MODEL" "$request_body_file"

  set +e
  curl_messages_api "$ANTHROPIC_API_URL" "x-api-key: ${ANTHROPIC_API_KEY}" \
    "$request_body_file" "$response_file" "$stderr_file" "$meta_file"
  local client_status="$?"
  set -e

  if [ "$client_status" -ne 0 ]; then
    LAST_EXIT_CODE="$client_status"
    LAST_REASON="curl_error"
    LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"
    return 1
  fi

  LAST_HTTP_STATUS="$(extract_http_status "$meta_file")"
  LAST_STDOUT_BYTES="$(file_size_bytes "$response_file")"
  LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"

  if ! [[ "$LAST_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    LAST_REASON="http_error"
    LAST_MESSAGE="$(json_error_message "$response_file")"
    return 1
  fi

  LAST_MESSAGE="$(json_error_message "$response_file")"
  if [ -n "$LAST_MESSAGE" ]; then
    LAST_REASON="api_error"
    return 1
  fi

  text="$(extract_text_response "$response_file" "$stderr_file")"
  if [ -z "$text" ]; then
    LAST_REASON="no_text_response"
    LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"
    return 1
  fi

  printf '%s' "$text" > "$text_output_file"
  return 0
}

try_heiyucode() {
  local text_output_file="$1"
  local request_body_file="$CLIENT_TMP_DIR/heiyucode-request.json"
  local response_file="$CLIENT_TMP_DIR/heiyucode-response.json"
  local stderr_file="$CLIENT_TMP_DIR/heiyucode-stderr.txt"
  local meta_file="$CLIENT_TMP_DIR/heiyucode-meta.txt"
  local text client_status auth_header_kind

  LAST_PROVIDER="heiyucode_claude_code"
  LAST_MODEL="$HEIYUCODE_MODEL"
  LAST_REASON="n/a"
  LAST_MESSAGE=""
  LAST_HTTP_STATUS="n/a"
  LAST_EXIT_CODE="0"
  LAST_AUTH_HEADER_KIND="authorization_bearer"
  LAST_ATTEMPTS="0"
  LAST_STDOUT_BYTES="0"
  LAST_STDERR_BYTES="0"

  if [ -z "$HEIYUCODE_TOKEN" ]; then
    LAST_REASON="credentials_missing"
    LAST_MESSAGE="HEIYUCODE_AUTH_TOKEN/HEIYUCODE_API_KEY not configured"
    return 1
  fi

  build_request_body "$HEIYUCODE_MODEL" "$request_body_file"

  run_heiyucode_attempt() {
    auth_header_kind="$1"
    LAST_AUTH_HEADER_KIND="$auth_header_kind"
    LAST_ATTEMPTS="$((LAST_ATTEMPTS + 1))"
    if [ "$auth_header_kind" = "x-api-key" ]; then
      curl_messages_api "$HEIYUCODE_API_URL" "x-api-key: ${HEIYUCODE_TOKEN}" \
        "$request_body_file" "$response_file" "$stderr_file" "$meta_file"
    else
      curl_messages_api "$HEIYUCODE_API_URL" "Authorization: Bearer ${HEIYUCODE_TOKEN}" \
        "$request_body_file" "$response_file" "$stderr_file" "$meta_file"
    fi
  }

  set +e
  run_heiyucode_attempt "authorization_bearer"
  client_status="$?"
  set -e

  LAST_EXIT_CODE="$client_status"
  LAST_HTTP_STATUS="$(extract_http_status "$meta_file")"
  LAST_STDOUT_BYTES="$(file_size_bytes "$response_file")"
  LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"

  if [ "$client_status" -eq 0 ] && { [ "$LAST_HTTP_STATUS" = "401" ] || [ "$LAST_HTTP_STATUS" = "403" ]; }; then
    set +e
    run_heiyucode_attempt "x-api-key"
    client_status="$?"
    set -e
    LAST_EXIT_CODE="$client_status"
    LAST_HTTP_STATUS="$(extract_http_status "$meta_file")"
    LAST_STDOUT_BYTES="$(file_size_bytes "$response_file")"
    LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"
  fi

  if [ "$client_status" -ne 0 ]; then
    LAST_REASON="curl_error"
    return 1
  fi

  if ! [[ "$LAST_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    LAST_REASON="http_error"
    LAST_MESSAGE="$(json_error_message "$response_file")"
    return 1
  fi

  LAST_MESSAGE="$(json_error_message "$response_file")"
  if [ -n "$LAST_MESSAGE" ]; then
    LAST_REASON="api_error"
    return 1
  fi

  text="$(extract_text_response "$response_file" "$stderr_file")"
  if [ -z "$text" ]; then
    LAST_REASON="no_text_response"
    LAST_STDERR_BYTES="$(file_size_bytes "$stderr_file")"
    return 1
  fi

  printf '%s' "$text" > "$text_output_file"
  return 0
}

write_success() {
  local text_output_file="$1"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  cp "$text_output_file" "$OUTPUT_FILE"
  echo "LLM client response received (provider=${LAST_PROVIDER} model=${LAST_MODEL} http_status=${LAST_HTTP_STATUS} auth_header_kind=${LAST_AUTH_HEADER_KIND} attempts=${LAST_ATTEMPTS} response_bytes=$(file_size_bytes "$OUTPUT_FILE"))"
}

CLIENT_OUTPUT="$CLIENT_TMP_DIR/message-output.txt"

case "$REQUESTED_PROVIDER" in
  ""|"auto")
    if [ -n "$HEIYUCODE_TOKEN" ]; then
      if try_heiyucode "$CLIENT_OUTPUT"; then
        write_success "$CLIENT_OUTPUT"
        exit 0
      fi

      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        diagnostic_line "warning"
        echo "LLM client falling back to Anthropic provider"
        if try_anthropic "$CLIENT_OUTPUT"; then
          write_success "$CLIENT_OUTPUT"
          exit 0
        fi
      fi

      diagnostic_line "error"
      exit 1
    fi

    if try_anthropic "$CLIENT_OUTPUT"; then
      write_success "$CLIENT_OUTPUT"
      exit 0
    fi

    diagnostic_line "error"
    exit 1
    ;;
  "heiyucode"|"heiyucode_claude_code"|"heiyu")
    if try_heiyucode "$CLIENT_OUTPUT"; then
      write_success "$CLIENT_OUTPUT"
      exit 0
    fi
    diagnostic_line "error"
    exit 1
    ;;
  "anthropic"|"anthropic_messages"|"claude")
    if try_anthropic "$CLIENT_OUTPUT"; then
      write_success "$CLIENT_OUTPUT"
      exit 0
    fi
    diagnostic_line "error"
    exit 1
    ;;
  *)
    fail "Unsupported SENTINEL_LLM_PROVIDER: ${REQUESTED_PROVIDER}"
    ;;
esac
