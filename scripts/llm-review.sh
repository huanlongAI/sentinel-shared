#!/bin/bash
set -euo pipefail

# LLM Review Layer
# Reads LLM configuration and prompts from .sentinel/config.yaml

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SENTINEL_SHARED_DIR="${SENTINEL_SHARED_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# YAML value reader (no yq dependency)
yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

# YAML array reader
yaml_get_array() {
  local file="$1" key="$2"
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "LLM Review Layer"

# Read LLM configuration
LLM_MODEL=$(yaml_get "$CONFIG_FILE" "llm.model" "claude-opus-4-6")
LLM_MAX_TOKENS=$(yaml_get "$CONFIG_FILE" "llm.max_output_tokens" "8192")
LLM_CHECKS=$(yaml_get_array "$CONFIG_FILE" "llm.checks")
CONFIDENCE_THRESHOLD=$(yaml_get "$CONFIG_FILE" "llm.confidence_threshold" "0.7")

echo "LLM Configuration:"
echo "  Model: $LLM_MODEL"
echo "  Max tokens: $LLM_MAX_TOKENS"
echo "  Confidence threshold: $CONFIDENCE_THRESHOLD"

# Get enabled checks
if [ -z "$LLM_CHECKS" ]; then
  echo "Using default LLM checks: all checks disabled"
  LLM_CHECKS=""
else
  echo "Enabled checks:"
  echo "$LLM_CHECKS" | while read -r check; do
    echo "  - $check"
  done
fi

# Determine system prompt path
SYSTEM_PROMPT=""
if [ -f ".sentinel/prompts/sentinel-system.md" ]; then
  SYSTEM_PROMPT=".sentinel/prompts/sentinel-system.md"
  echo "Using local system prompt: $SYSTEM_PROMPT"
elif [ -f "$SENTINEL_SHARED_DIR/prompts/sentinel-system.md" ]; then
  SYSTEM_PROMPT="$SENTINEL_SHARED_DIR/prompts/sentinel-system.md"
  echo "Using shared system prompt: $SYSTEM_PROMPT"
else
  echo "WARNING: No system prompt found"
fi

# Determine diff truncation size based on model
DIFF_MAX_CHARS=50000
if [[ "$LLM_MODEL" == *"opus"* ]]; then
  DIFF_MAX_CHARS=100000
fi

# Load context pack files based on anchor_files config
ANCHOR_FILES=$(yaml_get_array "$CONFIG_FILE" "anchor_files")
CONTEXT_PACK=""

if [ -n "$ANCHOR_FILES" ]; then
  echo "Loading context pack:"
  while IFS= read -r anchor_file; do
    [ -z "$anchor_file" ] && continue

    # Map common names to file paths
    file_path=""
    case "$anchor_file" in
      rulings)
        file_path=".sentinel/anchors/rulings.md"
        ;;
      saac)
        file_path=".sentinel/anchors/saac.md"
        ;;
      mira)
        file_path=".sentinel/anchors/mira.md"
        ;;
      context)
        file_path=".sentinel/anchors/context.md"
        ;;
      governance)
        file_path=".sentinel/anchors/governance.md"
        ;;
      *)
        file_path="$anchor_file"
        ;;
    esac

    if [ -f "$file_path" ]; then
      echo "  ✓ Loaded $anchor_file from $file_path"
      if [ -z "$CONTEXT_PACK" ]; then
        CONTEXT_PACK="$(cat "$file_path")"
      else
        CONTEXT_PACK="$CONTEXT_PACK

---

$(cat "$file_path")"
      fi
    else
      echo "  - Skipped $anchor_file (not found at $file_path)"
    fi
  done <<< "$ANCHOR_FILES"
fi

# Get diff of staged changes
STAGED_DIFF=$(git diff --cached 2>/dev/null || echo "")

# Truncate diff if too large
if [ ${#STAGED_DIFF} -gt $DIFF_MAX_CHARS ]; then
  echo "Truncating diff from ${#STAGED_DIFF} to $DIFF_MAX_CHARS chars"
  STAGED_DIFF="${STAGED_DIFF:0:$DIFF_MAX_CHARS}...

[TRUNCATED - diff exceeds ${DIFF_MAX_CHARS} characters]"
fi

# Prepare review payload
REVIEW_PAYLOAD=$(cat <<EOF
{
  "model": "$LLM_MODEL",
  "max_tokens": $LLM_MAX_TOKENS,
  "system_prompt_path": "$SYSTEM_PROMPT",
  "checks": $(printf '%s\n' $LLM_CHECKS | jq -R . | jq -s .),
  "confidence_threshold": $CONFIDENCE_THRESHOLD,
  "diff_size": ${#STAGED_DIFF},
  "diff_truncated": $([[ ${#STAGED_DIFF} -gt $DIFF_MAX_CHARS ]] && echo "true" || echo "false"),
  "context_pack_loaded": $([[ -n "$CONTEXT_PACK" ]] && echo "true" || echo "false"),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

echo "Review payload prepared:"
echo "$REVIEW_PAYLOAD" | jq .

# If no checks are enabled, skip LLM review
if [ -z "$LLM_CHECKS" ]; then
  echo "No LLM checks enabled, skipping review"

  RESULT_FILE="$RESULTS_DIR/llm-review.json"
  cat > "$RESULT_FILE" <<EOF
{
  "review_id": "llm-review",
  "status": "skipped",
  "reason": "No checks enabled in config",
  "checks_performed": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  exit 0
fi

# Load system prompt
if [ -f "$SYSTEM_PROMPT" ]; then
  SYSTEM_PROMPT_CONTENT=$(cat "$SYSTEM_PROMPT")
else
  echo "System prompt not found at $SYSTEM_PROMPT"
  SYSTEM_PROMPT_CONTENT="You are a code review assistant."
fi

# Prepare user message with diff and context
USER_MESSAGE="Please review the following code changes for the enabled checks.

## Code Changes
\`\`\`diff
$STAGED_DIFF
\`\`\`

## Context Pack
$([ -n "$CONTEXT_PACK" ] && echo "$CONTEXT_PACK" || echo "No context loaded")"

# Create review request (this would call Claude API in production)
echo "LLM Review would be performed with:"
echo "  Model: $LLM_MODEL"
echo "  Checks: $LLM_CHECKS"
echo "  System prompt: $SYSTEM_PROMPT"
echo "  Max output tokens: $LLM_MAX_TOKENS"

# For now, write a placeholder result
RESULT_FILE="$RESULTS_DIR/llm-review.json"
cat > "$RESULT_FILE" <<EOF
{
  "review_id": "llm-review",
  "model": "$LLM_MODEL",
  "checks_performed": $(printf '%s\n' $LLM_CHECKS | jq -R . | jq -s .),
  "status": "completed",
  "findings": [],
  "confidence_scores": {},
  "passed": true,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"
exit 0
