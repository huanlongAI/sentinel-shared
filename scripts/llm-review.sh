#!/bin/bash
set -euo pipefail

# LLM Review Layer — Consistency Sentinel
# Calls the configured Claude-compatible provider to perform semantic checks.

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SENTINEL_SHARED_DIR="${SENTINEL_SHARED_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$RESULTS_DIR"

cleanup_temp_files() {
  rm -f \
    "${SYSTEM_PROMPT_FILE:-}" \
    "${USER_MSG_FILE:-}" \
    "${REQUEST_BODY:-}" \
    "${API_RESPONSE_FILE:-}" \
    "${API_ERR_FILE:-}" \
    "${API_META_FILE:-}"
}

trap cleanup_temp_files EXIT

# --- YAML helpers (no yq) ---
trim_yaml_value() {
  sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[[:space:]]+|[[:space:]]+$//g' | tr -d '"' | tr -d "'"
}

yaml_section() {
  local file="$1" parent="$2"
  awk -v parent="$parent" '
    $0 ~ "^[[:space:]]*" parent ":[[:space:]]*($|#)" { in_section=1; next }
    in_section && $0 ~ "^[^[:space:]]" { exit }
    in_section { print }
  ' "$file" 2>/dev/null || true
}

yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 | trim_yaml_value || true)
  echo "${val:-$default}"
}

yaml_get_array() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":" { in_array=1; next }
    in_array && $0 ~ "^[^[:space:]]" { exit }
    in_array && $0 ~ "^[[:space:]]*-" {
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      gsub(/["'\''"]/, "", $0)
      print
    }
  ' "$file" 2>/dev/null || true
}

# Read a scalar value nested under a parent section
# Usage: yaml_get_nested config.yaml "llm" "model" "default"
yaml_get_nested() {
  local file="$1" parent="$2" key="$3" default="${4:-}"
  local val
  val=$(yaml_section "$file" "$parent" | grep -E "^[[:space:]]+${key}:" | head -1 | trim_yaml_value || true)
  echo "${val:-$default}"
}

# Read an array nested under a parent section
# Usage: yaml_get_nested_array config.yaml "llm" "checks"
yaml_get_nested_array() {
  local file="$1" parent="$2" key="$3"
  yaml_section "$file" "$parent" | awk -v key="$key" '
    $0 ~ "^[[:space:]]+" key ":" { in_array=1; next }
    in_array && $0 ~ "^[[:space:]]+[A-Za-z0-9_-]+:" { exit }
    in_array && $0 ~ "^[[:space:]]*-" {
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      gsub(/["'\''"]/, "", $0)
      print
    }
  ' || true
}

# Read key-value pairs under a section (for anchor_files)
# Returns: key=value per line
yaml_get_kv_pairs() {
  local file="$1" section="$2"
  yaml_section "$file" "$section" | \
    { grep -E "^[[:space:]]+[A-Za-z0-9_-]+:" || true; } | \
    sed -E 's/^[[:space:]]*//; s/:[[:space:]]*/=/' | tr -d '"' | tr -d "'"
}

echo "LLM Review Layer"

write_skip_result() {
  local reason="$1"
  cat > "$RESULTS_DIR/llm-review.json" <<EOF
{"review_id":"llm-review","status":"skipped","reason":"${reason}","passed":true,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}

write_error_result() {
  local reason="$1"
  jq -n \
    --arg provider "$LLM_PROVIDER" \
    --arg model "$LLM_MODEL" \
    --arg reason "$reason" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      review_id: "llm-review",
      check_name: "LLM Review",
      provider: $provider,
      model: $model,
      status: "error",
      reason: $reason,
      passed: false,
      escalate: true,
      timestamp: $timestamp
    }' > "$RESULTS_DIR/llm-review.json"
}

file_size_bytes() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -c < "$file" 2>/dev/null | tr -d ' ' || echo 0
  else
    echo 0
  fi
}

referenced_ruling_ids_from_diff() {
  printf '%s\n' "$DIFF_CONTENT" | { grep -Eo 'R-[0-9]{3,}([.][A-Za-z0-9]+)?' || true; } | sort -u
}

is_rulings_anchor_file() {
  local file="$1"
  [ "$(basename "$file")" = "RULINGS.md" ]
}

extract_single_ruling_section() {
  local file="$1" ruling_id="$2"
  awk -v ruling_id="$ruling_id" '
    BEGIN {
      escaped_ruling_id = ruling_id
      gsub(/[.]/, "[.]", escaped_ruling_id)
      heading_pattern = "^##+[[:space:]]+" escaped_ruling_id "([^0-9A-Za-z.]|$)"
      next_ruling_pattern = "^##+[[:space:]]+R-[0-9][0-9][0-9][0-9]*([.][A-Za-z0-9]+)?([^0-9A-Za-z.]|$)"
    }
    $0 ~ heading_pattern {
      in_section=1
    }
    in_section && $0 ~ next_ruling_pattern && $0 !~ heading_pattern {
      exit
    }
    in_section {
      print
    }
  ' "$file" 2>/dev/null || true
}

extract_referenced_rulings_context() {
  local file="$1" ids="$2"
  local max_chars="${RULINGS_EXCERPT_MAX_CHARS:-50000}"
  local context="" id section proposed

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    section="$(extract_single_ruling_section "$file" "$id")"
    [ -z "$section" ] && continue

    proposed="${context}
--- ${file}#${id} ---
${section}
"
    if [ "${#proposed}" -gt "$max_chars" ]; then
      if [ -z "$context" ]; then
        context="${proposed:0:$max_chars}
...[TRUNCATED rulings excerpt at ${max_chars} chars]
"
      else
        context="${context}
...[TRUNCATED rulings excerpt before ${id}; max ${max_chars} chars]
"
      fi
      break
    fi
    context="$proposed"
  done <<< "$ids"

  printf '%s' "$context"
}

extract_rulings_overview_context() {
  local file="$1"
  local max_chars="${RULINGS_OVERVIEW_MAX_CHARS:-50000}"
  local header_max_chars="${RULINGS_OVERVIEW_HEADER_MAX_CHARS:-4000}"
  local header headings context

  header="$(
    awk '
      /^##+[[:space:]]+R-[0-9][0-9][0-9][0-9]*([.][A-Za-z0-9]+)?([^0-9A-Za-z.]|$)/ { exit }
      { print }
    ' "$file" 2>/dev/null || true
  )"
  if [ "${#header}" -gt "$header_max_chars" ]; then
    header="${header:0:$header_max_chars}
...[TRUNCATED RULINGS prologue at ${header_max_chars} chars]"
  fi

  headings="$(
    awk '
      /^##+[[:space:]]+R-[0-9][0-9][0-9][0-9]*([.][A-Za-z0-9]+)?([^0-9A-Za-z.]|$)/ { print }
    ' "$file" 2>/dev/null || true
  )"

  context="--- ${file} overview ---
Large RULINGS anchor loaded as bounded overview because no direct R-id was found in the diff.
This overview provides the RULINGS prologue and ruling heading index. It does not replace exact ruling excerpts; if a specific R-id is referenced, Sentinel loads that section body separately.

## RULINGS prologue
${header}

## Ruling heading index
${headings}
"

  if [ "${#context}" -gt "$max_chars" ]; then
    context="${context:0:$max_chars}
...[TRUNCATED RULINGS overview at ${max_chars} chars]"
  fi

  printf '%s' "$context"
}

safe_stderr_tail() {
  local file="$1"
  if [ ! -s "$file" ]; then
    return 0
  fi

  tail -c 4000 "$file" | HEIYUCODE_TOKEN="${HEIYUCODE_TOKEN:-}" perl -0pe '
    BEGIN { $secret = $ENV{"HEIYUCODE_TOKEN"} // "" }
    if ($secret ne "") { s/\Q$secret\E/[redacted]/g }
  ' 2>/dev/null || printf '<stderr redaction failed>'
}

safe_response_tail() {
  local file="$1"
  if [ ! -s "$file" ]; then
    return 0
  fi

  tail -c 4000 "$file" | HEIYUCODE_TOKEN="${HEIYUCODE_TOKEN:-}" perl -0pe '
    BEGIN { $secret = $ENV{"HEIYUCODE_TOKEN"} // "" }
    if ($secret ne "") { s/\Q$secret\E/[redacted]/g }
  ' 2>/dev/null || printf '<response redaction failed>'
}

write_provider_error_result() {
  local reason="$1"
  local exit_code="$2"
  local duration_seconds="$3"
  local stdout_file="$4"
  local stderr_file="$5"
  local stdout_bytes stderr_bytes stderr_tail response_tail base_url_configured api_url_configured timestamp
  local provider_transport provider_http_status provider_auth_header_kind provider_attempts

  stdout_bytes="$(file_size_bytes "$stdout_file")"
  stderr_bytes="$(file_size_bytes "$stderr_file")"
  stderr_tail="$(safe_stderr_tail "$stderr_file")"
  response_tail="$(safe_response_tail "$stdout_file")"
  base_url_configured=false
  if [ -n "${HEIYUCODE_BASE_URL:-}" ]; then
    base_url_configured=true
  fi
  api_url_configured=false
  if [ -n "${HEIYUCODE_API_URL:-}" ]; then
    api_url_configured=true
  fi
  provider_transport="${PROVIDER_TRANSPORT:-n/a}"
  provider_http_status="${PROVIDER_HTTP_STATUS:-n/a}"
  provider_auth_header_kind="${PROVIDER_AUTH_HEADER_KIND:-n/a}"
  provider_attempts="${PROVIDER_ATTEMPTS:-0}"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --arg provider "$LLM_PROVIDER" \
    --arg model "$LLM_MODEL" \
    --arg transport "$provider_transport" \
    --arg status "error" \
    --arg error_type "provider_error" \
    --arg reason "$reason" \
    --arg http_status "$provider_http_status" \
    --arg auth_header_kind "$provider_auth_header_kind" \
    --arg stderr_tail "$stderr_tail" \
    --arg response_tail "$response_tail" \
    --arg timestamp "$timestamp" \
    --argjson exit_code "$exit_code" \
    --argjson attempts "$provider_attempts" \
    --argjson duration_seconds "$duration_seconds" \
    --argjson stdout_bytes "$stdout_bytes" \
    --argjson stderr_bytes "$stderr_bytes" \
    --argjson base_url_configured "$base_url_configured" \
    --argjson api_url_configured "$api_url_configured" \
    '{
      review_id: "llm-review",
      provider: $provider,
      model: $model,
      transport: $transport,
      status: $status,
      error_type: $error_type,
      reason: $reason,
      passed: false,
      escalate: true,
      http_status: $http_status,
      auth_header_kind: $auth_header_kind,
      exit_code: $exit_code,
      attempts: $attempts,
      duration_seconds: $duration_seconds,
      stdout_bytes: $stdout_bytes,
      stderr_bytes: $stderr_bytes,
      stderr_tail: $stderr_tail,
      response_tail: $response_tail,
      base_url_configured: $base_url_configured,
      api_url_configured: $api_url_configured,
      timestamp: $timestamp
    }' > "$RESULTS_DIR/llm-review.json"

  echo "::error::${reason} — fail closed (provider=${LLM_PROVIDER} model=${LLM_MODEL} transport=${provider_transport} http_status=${provider_http_status} auth_header_kind=${provider_auth_header_kind} exit_code=${exit_code} attempts=${provider_attempts} duration_seconds=${duration_seconds} stdout_bytes=${stdout_bytes} stderr_bytes=${stderr_bytes} base_url_configured=${base_url_configured} api_url_configured=${api_url_configured})"
}

run_with_timeout() {
  local timeout_seconds="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  local timeout_marker cmd_pid watchdog_pid status
  timeout_marker="$(mktemp)"
  rm -f "$timeout_marker"
  : > "$stdout_file"
  : > "$stderr_file"

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file" &
  cmd_pid="$!"
  (
    sleep "$timeout_seconds"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      printf '1\n' > "$timeout_marker"
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog_pid="$!"

  wait "$cmd_pid" 2>/dev/null
  status="$?"
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -f "$timeout_marker" ]; then
    rm -f "$timeout_marker"
    return 124
  fi
  rm -f "$timeout_marker"
  return "$status"
}

# --- Read LLM configuration (nested under llm:) ---
LLM_MODEL=$(yaml_get_nested "$CONFIG_FILE" "llm" "model" "claude-opus-4-6")
LLM_MAX_TOKENS=$(yaml_get_nested "$CONFIG_FILE" "llm" "max_output_tokens" "8192")
LLM_CHECKS=$(yaml_get_nested_array "$CONFIG_FILE" "llm" "checks")
CONFIDENCE_THRESHOLD=$(yaml_get_nested "$CONFIG_FILE" "llm" "confidence_threshold" "0.7")
CONFIG_PROVIDER=$(yaml_get_nested "$CONFIG_FILE" "llm" "provider" "auto")
REQUESTED_PROVIDER="${SENTINEL_LLM_PROVIDER:-$CONFIG_PROVIDER}"
ANTHROPIC_MODEL="$LLM_MODEL"
HEIYUCODE_BASE_URL="${HEIYUCODE_BASE_URL:-$(yaml_get_nested "$CONFIG_FILE" "llm" "heiyucode_base_url" "https://www.heiyucode.com")}"
HEIYUCODE_API_URL="${HEIYUCODE_API_URL:-${HEIYUCODE_BASE_URL%/}/v1/messages}"
HEIYUCODE_MODEL="${HEIYUCODE_MODEL:-$(yaml_get_nested "$CONFIG_FILE" "llm" "heiyucode_model" "$LLM_MODEL")}"
HEIYUCODE_TOKEN="${HEIYUCODE_AUTH_TOKEN:-${HEIYUCODE_API_KEY:-}}"
HEIYUCODE_CLIENT_TIMEOUT_SECONDS="${HEIYUCODE_CLIENT_TIMEOUT_SECONDS:-420}"

resolve_provider() {
  local requested="$1"
  case "$requested" in
    ""|"auto")
      if [ -n "$HEIYUCODE_TOKEN" ]; then
        echo "heiyucode_claude_code"
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "anthropic"
      else
        echo "none"
      fi
      ;;
    "anthropic"|"anthropic_messages"|"claude")
      echo "anthropic"
      ;;
    "heiyucode"|"heiyucode_claude_code"|"heiyu")
      echo "heiyucode_claude_code"
      ;;
    *)
      echo "unsupported"
      ;;
  esac
}

LLM_PROVIDER=$(resolve_provider "$REQUESTED_PROVIDER")
if [ "$LLM_PROVIDER" = "heiyucode_claude_code" ]; then
  LLM_MODEL="$HEIYUCODE_MODEL"
fi

echo "Config: provider=$LLM_PROVIDER model=$LLM_MODEL max_tokens=$LLM_MAX_TOKENS threshold=$CONFIDENCE_THRESHOLD"

if [ "$LLM_PROVIDER" = "unsupported" ]; then
  echo "::error::Unsupported LLM provider '$REQUESTED_PROVIDER' — fail closed"
  write_error_result "Unsupported LLM provider: ${REQUESTED_PROVIDER}"
  exit 1
fi

if [ "$LLM_PROVIDER" = "none" ]; then
  echo "::error::No LLM provider credentials configured — fail closed"
  write_error_result "No LLM provider credentials configured"
  exit 1
fi

if [ -z "$LLM_CHECKS" ]; then
  echo "No LLM checks enabled — skipping"
  write_skip_result "No checks enabled"
  exit 0
fi

echo "Enabled checks:"
echo "$LLM_CHECKS" | while read -r c; do [ -n "$c" ] && echo "  - $c"; done

# --- Load system prompt ---
SYSTEM_PROMPT_CONTENT=""
if [ -f ".sentinel/prompts/sentinel-system.md" ]; then
  SYSTEM_PROMPT_CONTENT=$(cat ".sentinel/prompts/sentinel-system.md")
  echo "Loaded local system prompt"
elif [ -f "$SENTINEL_SHARED_DIR/prompts/sentinel-system.md" ]; then
  SYSTEM_PROMPT_CONTENT=$(cat "$SENTINEL_SHARED_DIR/prompts/sentinel-system.md")
  echo "Loaded shared system prompt"
else
  SYSTEM_PROMPT_CONTENT="You are a governance consistency reviewer. Analyze code changes for policy violations."
  echo "Using fallback system prompt"
fi

# --- Detect changed files & build diff ---
if [ -n "${BASE_REF:-}" ]; then
  DIFF_CONTENT=$(git diff "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  DIFF_CONTENT=$(git diff HEAD~1 HEAD 2>/dev/null || echo "")
else
  DIFF_CONTENT=$(git diff --cached 2>/dev/null || echo "")
fi

if [ -z "$DIFF_CONTENT" ]; then
  echo "No diff to review — PASS"
  cat > "$RESULTS_DIR/llm-review.json" <<EOF
{"review_id":"llm-review","status":"completed","passed":true,"reason":"No diff","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

# Truncate diff for context window
DIFF_MAX_CHARS=80000
if [[ "$LLM_MODEL" == *"opus"* ]]; then
  DIFF_MAX_CHARS=150000
fi
TRUNCATED=false
if [ ${#DIFF_CONTENT} -gt $DIFF_MAX_CHARS ]; then
  DIFF_CONTENT="${DIFF_CONTENT:0:$DIFF_MAX_CHARS}
...[TRUNCATED at ${DIFF_MAX_CHARS} chars]"
  TRUNCATED=true
fi
echo "Diff size: ${#DIFF_CONTENT} chars (truncated=$TRUNCATED)"

# --- Build context pack from anchor files ---
CONTEXT_PACK=""
ANCHOR_KV=$(yaml_get_kv_pairs "$CONFIG_FILE" "anchor_files")
if [ -n "$ANCHOR_KV" ]; then
  echo "Loading context pack:"
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    file_path=$(echo "$pair" | sed 's/^[^=]*=//')
    file_path=$(echo "$file_path" | tr -d ' ')
    if [ -f "$file_path" ]; then
      FILE_SIZE=$(wc -c < "$file_path" | tr -d ' ')
      if [ "$FILE_SIZE" -lt 50000 ]; then
        CONTEXT_PACK="${CONTEXT_PACK}
--- ${file_path} ---
$(cat "$file_path")
"
        echo "  Loaded: $file_path (${FILE_SIZE}B)"
      elif is_rulings_anchor_file "$file_path"; then
        RULING_IDS="$(referenced_ruling_ids_from_diff)"
        RULINGS_CONTEXT="$(extract_referenced_rulings_context "$file_path" "$RULING_IDS")"
        if [ -n "$RULINGS_CONTEXT" ]; then
          CONTEXT_PACK="${CONTEXT_PACK}
${RULINGS_CONTEXT}"
          echo "  Extracted: $file_path refs=[$(printf '%s' "$RULING_IDS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')] from large anchor (${FILE_SIZE}B)"
        else
          RULINGS_CONTEXT="$(extract_rulings_overview_context "$file_path")"
          if [ -n "$RULINGS_CONTEXT" ]; then
            CONTEXT_PACK="${CONTEXT_PACK}
${RULINGS_CONTEXT}"
            echo "  Overview: $file_path no direct R-id refs; loaded bounded RULINGS overview (${FILE_SIZE}B)"
          else
            echo "  Skipped: $file_path (too large: ${FILE_SIZE}B; no referenced Ruling sections found)"
          fi
        fi
      else
        echo "  Skipped: $file_path (too large: ${FILE_SIZE}B)"
      fi
    else
      echo "  Not found: $file_path"
    fi
  done <<< "$ANCHOR_KV"
fi

# --- Build checks list for prompt ---
CHECKS_LIST=""
while IFS= read -r check_id; do
  [ -z "$check_id" ] && continue
  CHECKS_LIST="${CHECKS_LIST}- ${check_id}
"
done <<< "$LLM_CHECKS"

# --- Build user message ---
USER_MSG="Review the following code changes for these governance checks:

${CHECKS_LIST}

## Code Diff
\`\`\`diff
${DIFF_CONTENT}
\`\`\`

## Context (Anchor Files)
${CONTEXT_PACK:-No anchor files loaded.}

## Required Output Format
Respond ONLY with a JSON object (no markdown wrapping):
{
  \"verdict\": \"PASS\" | \"FAIL\" | \"ESCALATE\",
  \"checks\": {
    \"<CHECK_ID>\": {
      \"verdict\": \"PASS\" | \"FAIL\" | \"ESCALATE\",
      \"confidence\": 0.0-1.0,
      \"reason\": \"brief explanation\"
    }
  },
  \"summary\": \"one-line summary\"
}"

SYSTEM_PROMPT_FILE="$(mktemp)"
USER_MSG_FILE="$(mktemp)"
REQUEST_BODY="$(mktemp)"

printf '%s' "$SYSTEM_PROMPT_CONTENT" > "$SYSTEM_PROMPT_FILE"
printf '%s' "$USER_MSG" > "$USER_MSG_FILE"

build_messages_request_body() {
  local request_body_file="$1"
  jq -n \
    --arg model "$LLM_MODEL" \
    --argjson max_tokens "$LLM_MAX_TOKENS" \
    --rawfile system "$SYSTEM_PROMPT_FILE" \
    --rawfile user "$USER_MSG_FILE" \
    '{model:$model,max_tokens:$max_tokens,system:$system,messages:[{role:"user",content:$user}]}' \
    > "$request_body_file"
}

build_messages_request_body "$REQUEST_BODY"

# --- Call provider ---
echo "Calling LLM provider ($LLM_PROVIDER / $LLM_MODEL)..."

RESPONSE_TEXT=""
PROVIDER_TRANSPORT="${PROVIDER_TRANSPORT:-n/a}"
PROVIDER_HTTP_STATUS="${PROVIDER_HTTP_STATUS:-n/a}"
PROVIDER_AUTH_HEADER_KIND="${PROVIDER_AUTH_HEADER_KIND:-n/a}"
PROVIDER_EXIT_CODE="${PROVIDER_EXIT_CODE:-0}"
PROVIDER_DURATION_SECONDS="${PROVIDER_DURATION_SECONDS:-0}"
PROVIDER_STDOUT_BYTES="${PROVIDER_STDOUT_BYTES:-0}"
PROVIDER_STDERR_BYTES="${PROVIDER_STDERR_BYTES:-0}"
PROVIDER_ATTEMPTS="${PROVIDER_ATTEMPTS:-0}"
PROVIDER_BASE_URL_CONFIGURED="${PROVIDER_BASE_URL_CONFIGURED:-false}"
PROVIDER_API_URL_CONFIGURED="${PROVIDER_API_URL_CONFIGURED:-false}"
ANTHROPIC_ERROR_REASON=""

call_anthropic_provider() {
  local api_response api_error curl_status started response_text

  LLM_PROVIDER="anthropic"
  LLM_MODEL="$ANTHROPIC_MODEL"
  PROVIDER_TRANSPORT="messages-api"
  PROVIDER_HTTP_STATUS="n/a"
  PROVIDER_AUTH_HEADER_KIND="x-api-key"
  PROVIDER_EXIT_CODE="0"
  PROVIDER_ATTEMPTS="1"
  PROVIDER_DURATION_SECONDS="0"
  PROVIDER_STDOUT_BYTES="0"
  PROVIDER_STDERR_BYTES="0"
  PROVIDER_BASE_URL_CONFIGURED=false
  PROVIDER_API_URL_CONFIGURED=true

  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    ANTHROPIC_ERROR_REASON="ANTHROPIC_API_KEY not configured"
    return 1
  fi

  build_messages_request_body "$REQUEST_BODY"
  started="$(date +%s)"
  set +e
  api_response=$(curl -s --max-time 120 \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    --data-binary "@${REQUEST_BODY}" \
    "https://api.anthropic.com/v1/messages" 2>&1)
  curl_status="$?"
  set -e

  PROVIDER_EXIT_CODE="$curl_status"
  PROVIDER_DURATION_SECONDS="$(( $(date +%s) - started ))"
  PROVIDER_STDOUT_BYTES="${#api_response}"

  if [ "$curl_status" -ne 0 ]; then
    ANTHROPIC_ERROR_REASON="Claude API curl error"
    return 1
  fi

  if [ -z "$api_response" ]; then
    ANTHROPIC_ERROR_REASON="Empty API response"
    return 1
  fi

  api_error=$(printf '%s\n' "$api_response" | jq -r '.error.message // empty' 2>/dev/null || true)
  if [ -n "$api_error" ]; then
    ANTHROPIC_ERROR_REASON="API error: ${api_error}"
    return 1
  fi

  response_text=$(printf '%s\n' "$api_response" | jq -r '.content[0].text // empty' 2>/dev/null || true)
  if [ -z "$response_text" ]; then
    ANTHROPIC_ERROR_REASON="No text in response"
    return 1
  fi

  RESPONSE_TEXT="$response_text"
  return 0
}

can_fallback_to_anthropic() {
  [ "$REQUESTED_PROVIDER" = "auto" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]
}

fallback_to_anthropic_after_heiyucode_error() {
  local reason="$1"
  if ! can_fallback_to_anthropic; then
    return 1
  fi

  echo "::warning::${reason}; falling back to Anthropic provider"
  if call_anthropic_provider; then
    return 0
  fi

  echo "::error::Anthropic fallback failed after HeiyuCode provider error: ${ANTHROPIC_ERROR_REASON} — fail closed"
  write_error_result "Anthropic fallback failed after HeiyuCode provider error: ${ANTHROPIC_ERROR_REASON}"
  exit 1
}

if [ "$LLM_PROVIDER" = "anthropic" ]; then
  if ! call_anthropic_provider; then
    echo "::error::${ANTHROPIC_ERROR_REASON} — fail closed"
    write_error_result "$ANTHROPIC_ERROR_REASON"
    exit 1
  fi
elif [ "$LLM_PROVIDER" = "heiyucode_claude_code" ]; then
  PROVIDER_TRANSPORT="messages-api"
  PROVIDER_HTTP_STATUS="n/a"
  PROVIDER_AUTH_HEADER_KIND="n/a"
  HEIYUCODE_FALLBACK_SUCCEEDED=false

  if [ -z "$HEIYUCODE_TOKEN" ]; then
    write_provider_error_result "HeiyuCode token not configured" 0 0 /dev/null /dev/null
    exit 1
  fi

  if ! [[ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" -lt 1 ]; then
    HEIYUCODE_CLIENT_TIMEOUT_SECONDS=420
  fi

  API_RESPONSE_FILE="$(mktemp)"
  API_ERR_FILE="$(mktemp)"
  API_META_FILE="$(mktemp)"

  call_heiyucode_messages() {
    local auth_header_kind="$1"
    local response_file="$2"
    local stderr_file="$3"
    local meta_file="$4"
    local auth_header

    if [ "$auth_header_kind" = "x-api-key" ]; then
      auth_header="x-api-key: ${HEIYUCODE_TOKEN}"
    else
      auth_header="Authorization: Bearer ${HEIYUCODE_TOKEN}"
    fi

    run_with_timeout "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" "$meta_file" "$stderr_file" \
      curl -sS --max-time "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" \
        -o "$response_file" \
        -w "http_status=%{http_code}\ntime_total=%{time_total}\nsize_download=%{size_download}\n" \
        -X POST "$HEIYUCODE_API_URL" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "$auth_header" \
        --data-binary "@${REQUEST_BODY}"
  }

  extract_http_status() {
    local meta_file="$1"
    awk -F= '/^http_status=/{print $2; exit}' "$meta_file" 2>/dev/null || true
  }

  is_retryable_http_status() {
    case "$1" in
      429|500|502|503|504|520|522|524)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  client_started="$(date +%s)"
  heiyucode_base_url_configured=false
  if [ -n "$HEIYUCODE_BASE_URL" ]; then
    heiyucode_base_url_configured=true
  fi
  PROVIDER_BASE_URL_CONFIGURED="$heiyucode_base_url_configured"
  PROVIDER_API_URL_CONFIGURED=false
  if [ -n "$HEIYUCODE_API_URL" ]; then
    PROVIDER_API_URL_CONFIGURED=true
  fi
  echo "HeiyuCode Messages API timeout_seconds=${HEIYUCODE_CLIENT_TIMEOUT_SECONDS} base_url_configured=${heiyucode_base_url_configured}"

  AUTH_HEADER_KIND="authorization_bearer"
  HTTP_STATUS="n/a"
  PROVIDER_AUTH_HEADER_KIND="$AUTH_HEADER_KIND"
  PROVIDER_HTTP_STATUS="$HTTP_STATUS"

  run_heiyucode_attempt() {
    local auth_header_kind="$1"
    PROVIDER_ATTEMPTS="$(( ${PROVIDER_ATTEMPTS:-0} + 1 ))"
    set +e
    call_heiyucode_messages "$auth_header_kind" "$API_RESPONSE_FILE" "$API_ERR_FILE" "$API_META_FILE"
    client_status="$?"
    set -e
    client_duration="$(( $(date +%s) - client_started ))"
    HTTP_STATUS="$(extract_http_status "$API_META_FILE")"
    PROVIDER_HTTP_STATUS="$HTTP_STATUS"
    PROVIDER_EXIT_CODE="$client_status"
    PROVIDER_DURATION_SECONDS="$client_duration"
    PROVIDER_STDOUT_BYTES="$(file_size_bytes "$API_RESPONSE_FILE")"
    PROVIDER_STDERR_BYTES="$(file_size_bytes "$API_ERR_FILE")"
  }

  run_heiyucode_attempt "$AUTH_HEADER_KIND"

  if [ "$client_status" -eq 0 ] && { [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; }; then
    AUTH_HEADER_KIND="x-api-key"
    PROVIDER_AUTH_HEADER_KIND="$AUTH_HEADER_KIND"
    run_heiyucode_attempt "$AUTH_HEADER_KIND"
  fi

  retryable_retries=0
  while [ "$client_status" -eq 0 ] && is_retryable_http_status "$HTTP_STATUS" && [ "$retryable_retries" -lt 1 ]; do
    retryable_retries="$(( retryable_retries + 1 ))"
    echo "HeiyuCode Messages API HTTP ${HTTP_STATUS}; retrying once with auth_header_kind=${AUTH_HEADER_KIND}"
    run_heiyucode_attempt "$AUTH_HEADER_KIND"
  done

  if [ "$client_status" -eq 124 ]; then
    if fallback_to_anthropic_after_heiyucode_error "HeiyuCode Messages API timeout after ${HEIYUCODE_CLIENT_TIMEOUT_SECONDS}s"; then
      HEIYUCODE_FALLBACK_SUCCEEDED=true
    else
      write_provider_error_result "HeiyuCode Messages API timeout after ${HEIYUCODE_CLIENT_TIMEOUT_SECONDS}s" 124 "$client_duration" "$API_RESPONSE_FILE" "$API_ERR_FILE"
      exit 1
    fi
  fi
  if [ "$HEIYUCODE_FALLBACK_SUCCEEDED" != true ] && [ "$client_status" -ne 0 ]; then
    if fallback_to_anthropic_after_heiyucode_error "HeiyuCode Messages API curl error"; then
      HEIYUCODE_FALLBACK_SUCCEEDED=true
    else
      write_provider_error_result "HeiyuCode Messages API curl error" "$client_status" "$client_duration" "$API_RESPONSE_FILE" "$API_ERR_FILE"
      exit 1
    fi
  fi

  if [ "$HEIYUCODE_FALLBACK_SUCCEEDED" != true ] && ! [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    heiyucode_http_reason="HeiyuCode Messages API HTTP ${HTTP_STATUS}"
    if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
      heiyucode_http_reason="HeiyuCode Messages API auth error HTTP ${HTTP_STATUS}"
    fi
    if fallback_to_anthropic_after_heiyucode_error "$heiyucode_http_reason"; then
      HEIYUCODE_FALLBACK_SUCCEEDED=true
    else
      write_provider_error_result "$heiyucode_http_reason" 0 "$client_duration" "$API_RESPONSE_FILE" "$API_ERR_FILE"
      exit 1
    fi
  fi

  if [ "$HEIYUCODE_FALLBACK_SUCCEEDED" != true ]; then
    set +e
    RESPONSE_TEXT="$(jq -r '[.content[]? | select(.type == "text") | .text] | join("\n\n")' "$API_RESPONSE_FILE" 2>"$API_ERR_FILE")"
    parse_status="$?"
    set -e
    if [ "$parse_status" -ne 0 ]; then
      if fallback_to_anthropic_after_heiyucode_error "HeiyuCode Messages API returned invalid JSON"; then
        HEIYUCODE_FALLBACK_SUCCEEDED=true
      else
        write_provider_error_result "HeiyuCode Messages API returned invalid JSON" "$parse_status" "$client_duration" "$API_RESPONSE_FILE" "$API_ERR_FILE"
        exit 1
      fi
    fi
  fi

  if [ "$HEIYUCODE_FALLBACK_SUCCEEDED" != true ] && [ -z "$RESPONSE_TEXT" ]; then
    if fallback_to_anthropic_after_heiyucode_error "No text in response"; then
      HEIYUCODE_FALLBACK_SUCCEEDED=true
    else
      write_provider_error_result "No text in response" 0 "$client_duration" "$API_RESPONSE_FILE" "$API_ERR_FILE"
      exit 1
    fi
  fi

  if [ "$HEIYUCODE_FALLBACK_SUCCEEDED" = true ]; then
    echo "HeiyuCode provider failed; Anthropic fallback response received"
  fi
fi

if [ -z "$RESPONSE_TEXT" ]; then
  echo "::error::No text in provider response — fail closed"
  write_error_result "No text in response"
  exit 1
fi

echo "Response received (${#RESPONSE_TEXT} chars)"
echo "Provider diagnostics: provider=${LLM_PROVIDER} model=${LLM_MODEL} transport=${PROVIDER_TRANSPORT:-n/a} http_status=${PROVIDER_HTTP_STATUS:-n/a} auth_header_kind=${PROVIDER_AUTH_HEADER_KIND:-n/a} exit_code=${PROVIDER_EXIT_CODE:-0} attempts=${PROVIDER_ATTEMPTS:-0} duration_seconds=${PROVIDER_DURATION_SECONDS:-0} stdout_bytes=${PROVIDER_STDOUT_BYTES:-0} stderr_bytes=${PROVIDER_STDERR_BYTES:-0} base_url_configured=${PROVIDER_BASE_URL_CONFIGURED:-false} api_url_configured=${PROVIDER_API_URL_CONFIGURED:-false}"

write_review_parse_error() {
  local reason="$1"
  if [ -n "${API_RESPONSE_FILE:-}" ] && [ -f "${API_RESPONSE_FILE:-}" ]; then
    write_provider_error_result "$reason" 0 "${PROVIDER_DURATION_SECONDS:-0}" "$API_RESPONSE_FILE" "${API_ERR_FILE:-/dev/null}"
  else
    echo "::error::${reason} — fail closed"
    write_error_result "$reason"
  fi
}

fallback_to_anthropic_after_heiyucode_review_parse_error() {
  local reason="$1"
  if [ "$LLM_PROVIDER" != "heiyucode_claude_code" ]; then
    return 1
  fi
  if ! can_fallback_to_anthropic; then
    return 1
  fi

  if fallback_to_anthropic_after_heiyucode_error "$reason"; then
    API_RESPONSE_FILE=""
    API_ERR_FILE=""
    return 0
  fi

  return 1
}

recover_malformed_review_json() {
  local checks_file
  checks_file="$(mktemp)"
  printf '%s\n' "$LLM_CHECKS" > "$checks_file"
  printf '%s\n' "$REVIEW_JSON" | python3 -c '
import json
import re
import sys

checks_path = sys.argv[1]
text = sys.stdin.read()
check_ids = [line.strip() for line in open(checks_path, encoding="utf-8") if line.strip()]

verdict_values = re.findall(r"\"verdict\"\s*:\s*\"(PASS|FAIL|ESCALATE)\"", text)
if not verdict_values:
    sys.exit(1)

top_verdict = verdict_values[0]
effective_verdict = top_verdict
if "FAIL" in verdict_values:
    effective_verdict = "FAIL"
elif "ESCALATE" in verdict_values:
    effective_verdict = "ESCALATE"

checks = {}
for check_id in check_ids:
    marker = f"\"{check_id}\""
    idx = text.find(marker)
    if idx < 0:
        sys.exit(1)
    window = text[idx:idx + 2000]
    verdict_match = re.search(r"\"verdict\"\s*:\s*\"(PASS|FAIL|ESCALATE)\"", window)
    if not verdict_match:
        sys.exit(1)
    confidence_match = re.search(r"\"confidence\"\s*:\s*([0-9]+(?:\.[0-9]+)?)", window)
    confidence = float(confidence_match.group(1)) if confidence_match else None
    checks[check_id] = {
        "verdict": verdict_match.group(1),
        "confidence": confidence,
        "reason": "Recovered from malformed LLM JSON; original reason omitted because provider returned invalid JSON string escaping."
    }

print(json.dumps({
    "verdict": effective_verdict,
    "checks": checks,
    "summary": "Recovered verdict from malformed LLM JSON; provider response contained JSON-like output with invalid string escaping."
}, ensure_ascii=False))
' "$checks_file"
  rm -f "$checks_file"
}

extract_review_json_from_response() {
  local response_text="$1"
  local review_json

  review_json=$(printf '%s\n' "$response_text" | sed -n '/^{/,/^}/p' || true)
  if [ -z "$review_json" ]; then
    review_json=$(printf '%s\n' "$response_text" | sed -n '/```json/,/```/p' | grep -v '```' || true)
  fi
  if [ -z "$review_json" ]; then
    review_json=$(printf '%s\n' "$response_text" | sed -n '/```/,/```/p' | grep -v '```' || true)
  fi

  printf '%s\n' "$review_json"
}

# Extract JSON from response
REVIEW_JSON=$(extract_review_json_from_response "$RESPONSE_TEXT")

# Validate JSON and extract verdict
VERDICT="ESCALATE"
PASSED=true
if [ -z "$(printf '%s' "$REVIEW_JSON" | tr -d '[:space:]')" ]; then
  if fallback_to_anthropic_after_heiyucode_review_parse_error "Could not extract LLM review JSON"; then
    REVIEW_JSON=$(extract_review_json_from_response "$RESPONSE_TEXT")
  fi
  if [ -z "$(printf '%s' "$REVIEW_JSON" | tr -d '[:space:]')" ]; then
    write_review_parse_error "Could not extract LLM review JSON"
    exit 1
  fi
fi
if ! printf '%s\n' "$REVIEW_JSON" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
  RECOVERED_REVIEW_JSON="$(recover_malformed_review_json || true)"
  if [ -z "$(printf '%s' "$RECOVERED_REVIEW_JSON" | tr -d '[:space:]')" ] \
    || ! printf '%s\n' "$RECOVERED_REVIEW_JSON" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
    write_review_parse_error "Could not parse LLM JSON"
    exit 1
  fi
  echo "::warning::Recovered LLM review verdict from malformed JSON string escaping"
  REVIEW_JSON="$RECOVERED_REVIEW_JSON"
fi
VERDICT=$(printf '%s\n' "$REVIEW_JSON" | jq -r '.verdict // ""')
case "$VERDICT" in
  PASS|FAIL|ESCALATE)
    ;;
  *)
    write_review_parse_error "LLM review verdict missing or invalid"
    exit 1
    ;;
esac
REVIEW_DETAIL_JSON=$(printf '%s\n' "$REVIEW_JSON" | jq .)
SUMMARY=$(printf '%s\n' "$REVIEW_JSON" | jq -r '.summary // "No summary"')
echo "LLM verdict: $VERDICT"
echo "Summary: $SUMMARY"
printf '%s\n' "$REVIEW_JSON" | jq -r '.checks // {} | to_entries[] | "  \(.key): \(.value.verdict) (confidence: \(.value.confidence // "N/A"))"' 2>/dev/null || true

if [ "$VERDICT" = "FAIL" ] || [ "$VERDICT" = "ESCALATE" ]; then
  PASSED=false
fi

# --- Write result ---
RESULT_FILE="$RESULTS_DIR/llm-review.json"
cat > "$RESULT_FILE" <<EOF
{
  "review_id": "llm-review",
  "provider": "$LLM_PROVIDER",
  "model": "$LLM_MODEL",
  "transport": "${PROVIDER_TRANSPORT:-n/a}",
  "http_status": "${PROVIDER_HTTP_STATUS:-n/a}",
  "auth_header_kind": "${PROVIDER_AUTH_HEADER_KIND:-n/a}",
  "exit_code": ${PROVIDER_EXIT_CODE:-0},
  "attempts": ${PROVIDER_ATTEMPTS:-0},
  "duration_seconds": ${PROVIDER_DURATION_SECONDS:-0},
  "stdout_bytes": ${PROVIDER_STDOUT_BYTES:-0},
  "stderr_bytes": ${PROVIDER_STDERR_BYTES:-0},
  "base_url_configured": ${PROVIDER_BASE_URL_CONFIGURED:-false},
  "api_url_configured": ${PROVIDER_API_URL_CONFIGURED:-false},
  "status": "completed",
  "verdict": "$VERDICT",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "checks_performed": $(echo "$LLM_CHECKS" | jq -R . | jq -s .),
  "confidence_threshold": $CONFIDENCE_THRESHOLD,
  "response_length": ${#RESPONSE_TEXT},
  "diff_truncated": $TRUNCATED,
  "review_detail": $REVIEW_DETAIL_JSON,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::LLM review verdict: $VERDICT"
  exit 1
fi

echo "✓ LLM review: $VERDICT"
exit 0
