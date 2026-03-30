#!/bin/bash
set -euo pipefail

# ============================================================================
# Auto-Fix Script -- LLM-driven remediation for D-2 and D-6 violations
#
# Reads violation data from precheck result JSON, calls Claude API to
# generate fix suggestions, and outputs a patch file for downstream
# application. Does NOT apply changes directly -- caller workflow handles
# branch creation and PR.
#
# Usage: auto-fix.sh <check_id> <result_json> <repo_root>
#   check_id:    D-2 or D-6
#   result_json: path to the precheck result JSON file
#   repo_root:   path to the cloned repo root
#
# Output: writes fix commands to .sentinel/results/auto-fix-patch.sh
#         writes summary to .sentinel/results/auto-fix-summary.md
# ============================================================================

CHECK_ID="${1:-}"
RESULT_JSON="${2:-}"
REPO_ROOT="${3:-.}"
RESULTS_DIR="${REPO_ROOT}/.sentinel/results"

if [ -z "$CHECK_ID" ] || [ -z "$RESULT_JSON" ]; then
  echo "Usage: auto-fix.sh <check_id> <result_json> [repo_root]"
  exit 1
fi

if [ ! -f "$RESULT_JSON" ]; then
  echo "Result file not found: $RESULT_JSON"
  exit 1
fi

mkdir -p "$RESULTS_DIR"

echo "=== Auto-Fix: $CHECK_ID ==="
echo "Result file: $RESULT_JSON"
echo "Repo root: $REPO_ROOT"

# --- Check if result shows failure ---
PASSED=$(jq -r 'if .passed == null then "true" else (.passed | tostring) end' "$RESULT_JSON" 2>/dev/null || echo "true")
if [ "$PASSED" = "true" ]; then
  echo "Check $CHECK_ID passed -- nothing to fix"
  exit 0
fi

# --- Extract violation details ---
case "$CHECK_ID" in
  D-2)
    # D-2 violations format: ["file.txt: contains forbidden term 'TODO'", ...]
    VIOLATIONS=$(jq -r '.violations[]? // empty' "$RESULT_JSON" 2>/dev/null || true)
    if [ -z "$VIOLATIONS" ]; then
      echo "No violations found in result JSON"
      exit 0
    fi

    # Build file-level context for LLM
    # Extract unique files and their violation lines
    CONTEXT=""
    declare -A FILE_TERMS
    while IFS= read -r violation; do
      [ -z "$violation" ] && continue
      FILE=$(echo "$violation" | sed "s/: contains forbidden term '.*'//")
      TERM=$(echo "$violation" | grep -oP "(?<=forbidden term ').*(?=')" || true)
      [ -z "$FILE" ] || [ -z "$TERM" ] && continue
      if [ -f "${REPO_ROOT}/${FILE}" ]; then
        # Get lines containing the term (with line numbers)
        MATCHES=$(grep -inw "$TERM" "${REPO_ROOT}/${FILE}" 2>/dev/null | head -10 || true)
        if [ -n "$MATCHES" ]; then
          CONTEXT="${CONTEXT}
### File: ${FILE}
Term: ${TERM}
Matching lines:
${MATCHES}
"
        fi
      fi
    done <<< "$VIOLATIONS"

    SYSTEM_PROMPT="You are a code maintenance assistant. Your task is to replace forbidden terms in source code with appropriate alternatives.

Rules:
- TODO -> Replace with a tracked comment like 'NOTE: tracked in backlog' or remove if the task is done
- FIXME -> Replace with 'NOTE: needs review' or fix the actual issue described
- HACK -> Replace with 'WORKAROUND:' and add a brief justification
- XXX -> Remove or replace with a descriptive comment
- TEMP -> Replace with 'INTERIM:' if still needed, or remove if no longer needed
- DEPRECATED -> Keep if it is a proper @deprecated annotation; remove from inline comments
- BUG -> Replace with 'KNOWN-ISSUE:' or 'NOTE:'

Output ONLY a bash script that uses sed -i commands to make the replacements.
Each sed command must target a specific line number in a specific file.
Format: sed -i 'Ns/old/new/' path/to/file
Do NOT output explanations -- only the sed commands."

    USER_PROMPT="Fix the following forbidden term violations:
${CONTEXT}

Generate sed commands to replace each forbidden term with an appropriate alternative. Be conservative -- prefer minimal changes."
    ;;

  D-6)
    # D-6 issues format: ["file.swift: 3 hardcoded color value(s) found ...", ...]
    VIOLATIONS=$(jq -r '.issues[]? // empty' "$RESULT_JSON" 2>/dev/null || true)
    if [ -z "$VIOLATIONS" ]; then
      echo "No violations found in result JSON"
      exit 0
    fi

    # Extract hardcoded colors with line context
    CONTEXT=""
    COLOR_REGEX='#[0-9a-fA-F]{3,8}|rgba?\([0-9, .%]+\)|UIColor\(red:|Color\(red:|hsl\(|hsla\('
    while IFS= read -r issue; do
      [ -z "$issue" ] && continue
      FILE=$(echo "$issue" | sed 's/: [0-9]* hardcoded color.*//')
      if [ -f "${REPO_ROOT}/${FILE}" ]; then
        MATCHES=$(grep -noE "$COLOR_REGEX" "${REPO_ROOT}/${FILE}" 2>/dev/null | head -20 || true)
        if [ -n "$MATCHES" ]; then
          CONTEXT="${CONTEXT}
### File: ${FILE}
Hardcoded colors found:
${MATCHES}
"
        fi
      fi
    done <<< "$VIOLATIONS"

    # Check if guanghe INTEGRATION-PROTOCOL exists for token reference
    TOKEN_REF=""
    if [ -f "${REPO_ROOT}/guanghe/INTEGRATION-PROTOCOL.md" ]; then
      TOKEN_REF=$(head -100 "${REPO_ROOT}/guanghe/INTEGRATION-PROTOCOL.md" 2>/dev/null || true)
    fi

    SYSTEM_PROMPT="You are a design system migration assistant. Your task is to replace hardcoded color values in UI code with design system tokens.

Token naming convention (guanghe design system):
- Primary colors: GHColor.primary, GHColor.primaryVariant
- Background: GHColor.background, GHColor.surface
- Text: GHColor.textPrimary, GHColor.textSecondary
- Accent: GHColor.accent, GHColor.accentVariant
- Error/Warning: GHColor.error, GHColor.warning, GHColor.success
- Border: GHColor.border, GHColor.divider
- For hex #FFFFFF or rgb(255,255,255): GHColor.white
- For hex #000000 or rgb(0,0,0): GHColor.black

For SwiftUI: use Color.ghPrimary, Color.ghBackground, etc.
For CSS/SCSS: use var(--gh-primary), var(--gh-background), etc.
For React/TSX: use tokens.primary, tokens.background, etc.

Output ONLY a bash script with sed -i commands to make the replacements.
Each sed command must target a specific line number in a specific file.
Format: sed -i 'Ns/old/new/' path/to/file
Do NOT output explanations -- only the sed commands."

    USER_PROMPT="Replace the following hardcoded colors with design system tokens:
${CONTEXT}

${TOKEN_REF:+Design system reference:
${TOKEN_REF}}

Generate sed commands for each hardcoded color. Map colors to the closest semantic token. Be conservative -- if unsure, add a comment with the original value."
    ;;

  *)
    echo "Unsupported check_id: $CHECK_ID (supported: D-2, D-6)"
    exit 1
    ;;
esac

# --- Call Claude API ---
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "ANTHROPIC_API_KEY not set -- cannot generate fixes"
  echo "Falling back to violation report only"

  # Write summary without LLM fixes
  {
    echo "## Auto-Fix Report: $CHECK_ID"
    echo ""
    echo "LLM auto-fix unavailable (no API key). Violations detected:"
    echo ""
    echo '```'
    echo "$VIOLATIONS"
    echo '```'
    echo ""
    echo "Please fix manually."
  } > "$RESULTS_DIR/auto-fix-summary.md"

  exit 0
fi

echo "Calling Claude API for fix generation..."

# Build API request
API_URL="https://api.anthropic.com/v1/messages"
REQUEST_BODY=$(jq -n \
  --arg model "claude-sonnet-4-6" \
  --arg system "$SYSTEM_PROMPT" \
  --arg user "$USER_PROMPT" \
  '{
    model: $model,
    max_tokens: 4096,
    system: $system,
    messages: [
      { role: "user", content: $user }
    ]
  }')

RESPONSE=$(curl -s --max-time 60 \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST_BODY" \
  "$API_URL" 2>/dev/null || echo '{"error": "API call failed"}')

# Extract text content from response
LLM_OUTPUT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null || true)

if [ -z "$LLM_OUTPUT" ]; then
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null || echo "Unknown error")
  echo "LLM API error: $ERROR_MSG"
  echo "Falling back to violation report only"

  {
    echo "## Auto-Fix Report: $CHECK_ID"
    echo ""
    echo "LLM fix generation failed: $ERROR_MSG"
    echo ""
    echo "Violations:"
    echo '```'
    echo "$VIOLATIONS"
    echo '```'
  } > "$RESULTS_DIR/auto-fix-summary.md"

  exit 0
fi

echo "LLM generated fix commands"

# --- Extract and validate sed commands ---
# Only keep lines that look like valid sed commands (safety filter)
PATCH_FILE="$RESULTS_DIR/auto-fix-patch.sh"
{
  echo "#!/bin/bash"
  echo "set -euo pipefail"
  echo "# Auto-generated fix patch for $CHECK_ID"
  echo "# Generated by Claude API -- review before applying"
  echo ""
  echo "cd \"${REPO_ROOT}\""
  echo ""
  # Extract only sed -i commands from LLM output (security: filter out everything else)
  echo "$LLM_OUTPUT" | grep -E "^sed -i " || true
} > "$PATCH_FILE"
chmod +x "$PATCH_FILE"

# Count commands
CMD_COUNT=$(grep -c "^sed -i " "$PATCH_FILE" || echo "0")
echo "Generated $CMD_COUNT fix commands"

# --- Generate summary ---
SUMMARY_FILE="$RESULTS_DIR/auto-fix-summary.md"
{
  echo "## Auto-Fix Report: $CHECK_ID"
  echo ""
  echo "Generated **${CMD_COUNT}** fix commands via Claude API."
  echo ""
  echo "### Violations Found"
  echo ""
  echo '```'
  echo "$VIOLATIONS"
  echo '```'
  echo ""
  echo "### Generated Fix Commands"
  echo ""
  echo '```bash'
  grep "^sed -i " "$PATCH_FILE" || echo "(none)"
  echo '```'
  echo ""
  echo "### Review Checklist"
  echo ""
  echo "- [ ] All sed commands target correct files and line numbers"
  echo "- [ ] Replacement terms are appropriate for the context"
  echo "- [ ] No unintended side effects on adjacent code"
  echo "- [ ] Build/tests pass after applying fixes"
} > "$SUMMARY_FILE"

echo "Summary written to $SUMMARY_FILE"
echo "Patch written to $PATCH_FILE"
echo "=== Auto-Fix: $CHECK_ID COMPLETE ==="
