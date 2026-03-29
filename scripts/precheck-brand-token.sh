#!/bin/bash
set -euo pipefail

# D-6: Brand Token hardcode detection (DBC-001)
# Scans UI/style files for hardcoded color values instead of design system tokens
# Config key: brand_token_file_patterns (file globs, e.g. *.swift, *.css)
# Config key: brand_token_allowlist (allowed raw values)
# Depends on: guanghe/INTEGRATION-PROTOCOL.md

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

mkdir -p "$RESULTS_DIR"

yaml_get_array() {
  local file="$1" key="$2"
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "D-6: Brand Token hardcode detection"

# Detect changed files
if [ -n "${BASE_REF:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

# Read file patterns from config
FILE_PATTERNS=$(yaml_get_array "$CONFIG_FILE" "brand_token_file_patterns")
ALLOWLIST=$(yaml_get_array "$CONFIG_FILE" "brand_token_allowlist")

if [ -z "$FILE_PATTERNS" ]; then
  # Default UI file patterns
  FILE_PATTERNS="*.swift
*.css
*.scss
*.less
*.tsx
*.jsx
*.vue"
  echo "Using default file patterns"
fi

# Hardcoded color patterns to detect
# Hex colors: #RGB, #RRGGBB, #RRGGBBAA
# RGB/RGBA: rgb(r,g,b), rgba(r,g,b,a)
# UIColor/Color with literal values
COLOR_REGEX='#[0-9a-fA-F]{3,8}|rgba?\([0-9, .%]+\)|UIColor\(red:|Color\(red:|hsl\(|hsla\('

PASSED=true
ISSUES=()
SCANNED=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  # Check if file matches any pattern
  MATCHES=false
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    ext="${pattern#*.}"
    if [[ "$file" == *".${ext}" ]]; then
      MATCHES=true
      break
    fi
  done <<< "$FILE_PATTERNS"

  if [ "$MATCHES" = true ]; then
    SCANNED=$((SCANNED + 1))
    # Search for hardcoded colors
    FOUND_COLORS=$(grep -noE "$COLOR_REGEX" "$file" 2>/dev/null || true)

    if [ -n "$FOUND_COLORS" ]; then
      # Filter out allowlisted values
      VIOLATIONS=""
      while IFS= read -r match; do
        [ -z "$match" ] && continue
        COLOR_VAL=$(echo "$match" | sed 's/^[0-9]*://')
        ALLOWED=false
        while IFS= read -r allow; do
          [ -z "$allow" ] && continue
          if [ "$COLOR_VAL" = "$allow" ]; then
            ALLOWED=true
            break
          fi
        done <<< "$ALLOWLIST"
        if [ "$ALLOWED" = false ]; then
          VIOLATIONS="${VIOLATIONS}${match}\n"
        fi
      done <<< "$FOUND_COLORS"

      if [ -n "$VIOLATIONS" ]; then
        COUNT=$(echo -e "$VIOLATIONS" | grep -c . || true)
        ISSUES+=("$file: $COUNT hardcoded color value(s) found — use design system tokens")
        PASSED=false
        echo "✗ $file: $COUNT hardcoded color(s)"
      else
        echo "✓ $file: colors are allowlisted"
      fi
    else
      echo "✓ $file: no hardcoded colors"
    fi
  fi
done <<< "$CHANGED_FILES"

if [ $SCANNED -eq 0 ]; then
  echo "No UI/style files in changed files — PASS"
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d6-brand-token.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-6",
  "check_name": "Brand Token",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "files_scanned": $SCANNED,
  "issues": $(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}"; fi | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-6 Brand Token check failed — hardcoded colors detected"
  exit 1
fi

echo "✓ D-6 PASS"
exit 0
