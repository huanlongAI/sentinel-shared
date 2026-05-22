#!/bin/bash
set -euo pipefail

# LLM Review Layer — Consistency Sentinel
# Calls the configured Claude-compatible provider to perform semantic checks.

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SENTINEL_SHARED_DIR="${SENTINEL_SHARED_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$RESULTS_DIR"

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

file_size_bytes() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -c < "$file" 2>/dev/null | tr -d ' ' || echo 0
  else
    echo 0
  fi
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

write_provider_error_result() {
  local reason="$1"
  local exit_code="$2"
  local duration_seconds="$3"
  local stdout_file="$4"
  local stderr_file="$5"
  local stdout_bytes stderr_bytes stderr_tail base_url_configured timestamp

  stdout_bytes="$(file_size_bytes "$stdout_file")"
  stderr_bytes="$(file_size_bytes "$stderr_file")"
  stderr_tail="$(safe_stderr_tail "$stderr_file")"
  base_url_configured=false
  if [ -n "${HEIYUCODE_BASE_URL:-}" ]; then
    base_url_configured=true
  fi
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --arg provider "$LLM_PROVIDER" \
    --arg model "$LLM_MODEL" \
    --arg status "error" \
    --arg error_type "provider_error" \
    --arg reason "$reason" \
    --arg stderr_tail "$stderr_tail" \
    --arg timestamp "$timestamp" \
    --argjson exit_code "$exit_code" \
    --argjson duration_seconds "$duration_seconds" \
    --argjson stdout_bytes "$stdout_bytes" \
    --argjson stderr_bytes "$stderr_bytes" \
    --argjson base_url_configured "$base_url_configured" \
    '{
      review_id: "llm-review",
      provider: $provider,
      model: $model,
      status: $status,
      error_type: $error_type,
      reason: $reason,
      passed: true,
      escalate: true,
      exit_code: $exit_code,
      duration_seconds: $duration_seconds,
      stdout_bytes: $stdout_bytes,
      stderr_bytes: $stderr_bytes,
      stderr_tail: $stderr_tail,
      base_url_configured: $base_url_configured,
      timestamp: $timestamp
    }' > "$RESULTS_DIR/llm-review.json"

  echo "::warning::${reason} — ESCALATE (provider=${LLM_PROVIDER} model=${LLM_MODEL} exit_code=${exit_code} duration_seconds=${duration_seconds} stdout_bytes=${stdout_bytes} stderr_bytes=${stderr_bytes} base_url_configured=${base_url_configured})"
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
HEIYUCODE_BASE_URL="${HEIYUCODE_BASE_URL:-$(yaml_get_nested "$CONFIG_FILE" "llm" "heiyucode_base_url" "https://www.heiyucode.com")}"
HEIYUCODE_MODEL="${HEIYUCODE_MODEL:-$(yaml_get_nested "$CONFIG_FILE" "llm" "heiyucode_model" "$LLM_MODEL")}"
HEIYUCODE_TOKEN="${HEIYUCODE_AUTH_TOKEN:-${HEIYUCODE_API_KEY:-}}"
HEIYUCODE_CLIENT_TIMEOUT_SECONDS="${HEIYUCODE_CLIENT_TIMEOUT_SECONDS:-420}"
HEIYUCODE_INSTALL_TIMEOUT_SECONDS="${HEIYUCODE_INSTALL_TIMEOUT_SECONDS:-120}"

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
  echo "::warning::Unsupported LLM provider '$REQUESTED_PROVIDER' — skipping LLM review"
  write_skip_result "Unsupported LLM provider: ${REQUESTED_PROVIDER}"
  exit 0
fi

if [ "$LLM_PROVIDER" = "none" ]; then
  echo "::warning::No LLM provider credentials configured — skipping LLM review"
  write_skip_result "No LLM provider credentials configured"
  exit 0
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

# --- Call provider ---
echo "Calling LLM provider ($LLM_PROVIDER / $LLM_MODEL)..."

SYSTEM_JSON=$(echo "$SYSTEM_PROMPT_CONTENT" | jq -Rsa .)
USER_JSON=$(echo "$USER_MSG" | jq -Rsa .)

RESPONSE_TEXT=""
if [ "$LLM_PROVIDER" = "anthropic" ]; then
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "::warning::ANTHROPIC_API_KEY not set — skipping LLM review"
    write_skip_result "ANTHROPIC_API_KEY not configured"
    exit 0
  fi

  API_RESPONSE=$(curl -s --max-time 120 \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
      \"model\": \"${LLM_MODEL}\",
      \"max_tokens\": ${LLM_MAX_TOKENS},
      \"system\": ${SYSTEM_JSON},
      \"messages\": [{\"role\": \"user\", \"content\": ${USER_JSON}}]
    }" \
    "https://api.anthropic.com/v1/messages" 2>&1) || true

  if [ -z "$API_RESPONSE" ]; then
    echo "::warning::Claude API returned empty response — ESCALATE"
    cat > "$RESULTS_DIR/llm-review.json" <<EOF
{"review_id":"llm-review","provider":"$LLM_PROVIDER","model":"$LLM_MODEL","status":"error","reason":"Empty API response","passed":true,"escalate":true,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
    exit 0
  fi

  API_ERROR=$(echo "$API_RESPONSE" | jq -r '.error.message // empty' 2>/dev/null || true)
  if [ -n "$API_ERROR" ]; then
    echo "::warning::Claude API error: $API_ERROR — ESCALATE"
    cat > "$RESULTS_DIR/llm-review.json" <<EOF
{"review_id":"llm-review","provider":"$LLM_PROVIDER","model":"$LLM_MODEL","status":"error","reason":"API error: ${API_ERROR}","passed":true,"escalate":true,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
    exit 0
  fi

  RESPONSE_TEXT=$(echo "$API_RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null || true)
elif [ "$LLM_PROVIDER" = "heiyucode_claude_code" ]; then
  if [ -z "$HEIYUCODE_TOKEN" ]; then
    write_provider_error_result "HeiyuCode token not configured" 0 0 /dev/null /dev/null
    exit 0
  fi

  if ! [[ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" -lt 1 ]; then
    HEIYUCODE_CLIENT_TIMEOUT_SECONDS=420
  fi
  if ! [[ "$HEIYUCODE_INSTALL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEIYUCODE_INSTALL_TIMEOUT_SECONDS" -lt 1 ]; then
    HEIYUCODE_INSTALL_TIMEOUT_SECONDS=120
  fi

  CLAUDE_BIN="$(command -v claude || true)"
  if [ -z "$CLAUDE_BIN" ]; then
    if ! command -v npm >/dev/null 2>&1; then
      write_provider_error_result "claude CLI unavailable" 127 0 /dev/null /dev/null
      exit 0
    fi

    NPM_OUT="$(mktemp)"
    NPM_ERR="$(mktemp)"
    install_started="$(date +%s)"
    set +e
    run_with_timeout "$HEIYUCODE_INSTALL_TIMEOUT_SECONDS" "$NPM_OUT" "$NPM_ERR" \
      npm install --prefix /tmp/sentinel-claude-code-cli --no-save @anthropic-ai/claude-code@1.0.100
    install_status="$?"
    set -e
    if [ "$install_status" -ne 0 ]; then
      install_duration="$(( $(date +%s) - install_started ))"
      if [ "$install_status" -eq 124 ]; then
        write_provider_error_result "Claude Code client install timeout after ${HEIYUCODE_INSTALL_TIMEOUT_SECONDS}s" 124 "$install_duration" "$NPM_OUT" "$NPM_ERR"
      else
        write_provider_error_result "Claude Code client install failed" "$install_status" "$install_duration" "$NPM_OUT" "$NPM_ERR"
      fi
      exit 0
    fi
    CLAUDE_BIN="/tmp/sentinel-claude-code-cli/node_modules/.bin/claude"
  fi

  CLAUDE_PROMPT="${SYSTEM_PROMPT_CONTENT}

${USER_MSG}"
  CLAUDE_OUT="$(mktemp)"
  CLAUDE_ERR="$(mktemp)"
  client_started="$(date +%s)"
  heiyucode_base_url_configured=false
  if [ -n "$HEIYUCODE_BASE_URL" ]; then
    heiyucode_base_url_configured=true
  fi
  echo "HeiyuCode Claude Code client timeout_seconds=${HEIYUCODE_CLIENT_TIMEOUT_SECONDS} base_url_configured=${heiyucode_base_url_configured}"

  set +e
  run_with_timeout "$HEIYUCODE_CLIENT_TIMEOUT_SECONDS" "$CLAUDE_OUT" "$CLAUDE_ERR" \
    env \
      ANTHROPIC_AUTH_TOKEN="$HEIYUCODE_TOKEN" \
      ANTHROPIC_BASE_URL="$HEIYUCODE_BASE_URL" \
      ANTHROPIC_MODEL="$LLM_MODEL" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      "$CLAUDE_BIN" -p "$CLAUDE_PROMPT" --output-format text --model "$LLM_MODEL"
  client_status="$?"
  set -e
  client_duration="$(( $(date +%s) - client_started ))"

  if [ "$client_status" -eq 124 ]; then
    write_provider_error_result "HeiyuCode Claude Code client timeout after ${HEIYUCODE_CLIENT_TIMEOUT_SECONDS}s" 124 "$client_duration" "$CLAUDE_OUT" "$CLAUDE_ERR"
    exit 0
  fi
  if [ "$client_status" -ne 0 ]; then
    write_provider_error_result "HeiyuCode Claude Code client error" "$client_status" "$client_duration" "$CLAUDE_OUT" "$CLAUDE_ERR"
    exit 0
  fi

  if [ ! -s "$CLAUDE_OUT" ]; then
    write_provider_error_result "No text in response" 0 "$client_duration" "$CLAUDE_OUT" "$CLAUDE_ERR"
    exit 0
  fi

  RESPONSE_TEXT="$(cat "$CLAUDE_OUT")"
fi

if [ -z "$RESPONSE_TEXT" ]; then
  echo "::warning::No text in provider response — ESCALATE"
  cat > "$RESULTS_DIR/llm-review.json" <<EOF
{"review_id":"llm-review","provider":"$LLM_PROVIDER","model":"$LLM_MODEL","status":"error","reason":"No text in response","passed":true,"escalate":true,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

echo "Response received (${#RESPONSE_TEXT} chars)"

# Extract JSON from response
REVIEW_JSON=$(echo "$RESPONSE_TEXT" | sed -n '/^{/,/^}/p' || true)
if [ -z "$REVIEW_JSON" ]; then
  REVIEW_JSON=$(echo "$RESPONSE_TEXT" | sed -n '/```json/,/```/p' | grep -v '```' || true)
fi
if [ -z "$REVIEW_JSON" ]; then
  REVIEW_JSON=$(echo "$RESPONSE_TEXT" | sed -n '/```/,/```/p' | grep -v '```' || true)
fi

# Validate JSON and extract verdict
VERDICT="ESCALATE"
PASSED=true
if echo "$REVIEW_JSON" | jq . >/dev/null 2>&1; then
  VERDICT=$(echo "$REVIEW_JSON" | jq -r '.verdict // "ESCALATE"')
  SUMMARY=$(echo "$REVIEW_JSON" | jq -r '.summary // "No summary"')
  echo "LLM verdict: $VERDICT"
  echo "Summary: $SUMMARY"
  echo "$REVIEW_JSON" | jq -r '.checks // {} | to_entries[] | "  \(.key): \(.value.verdict) (confidence: \(.value.confidence // "N/A"))"' 2>/dev/null || true

  if [ "$VERDICT" = "FAIL" ]; then
    PASSED=false
  fi
else
  echo "::warning::Could not parse LLM JSON — ESCALATE"
  REVIEW_JSON="{}"
fi

# --- Write result ---
RESULT_FILE="$RESULTS_DIR/llm-review.json"
cat > "$RESULT_FILE" <<EOF
{
  "review_id": "llm-review",
  "provider": "$LLM_PROVIDER",
  "model": "$LLM_MODEL",
  "status": "completed",
  "verdict": "$VERDICT",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "checks_performed": $(echo "$LLM_CHECKS" | jq -R . | jq -s .),
  "confidence_threshold": $CONFIDENCE_THRESHOLD,
  "response_length": ${#RESPONSE_TEXT},
  "diff_truncated": $TRUNCATED,
  "review_detail": $(echo "$REVIEW_JSON" | jq . 2>/dev/null || echo "{}"),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::LLM review verdict: FAIL"
  exit 1
fi

echo "✓ LLM review: $VERDICT"
exit 0
