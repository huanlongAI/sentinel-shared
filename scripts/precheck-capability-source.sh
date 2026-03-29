#!/bin/bash
set -euo pipefail

# D-5: Capability source annotation scan (SAC-003)
# Checks that architecture/tech-selection docs include capability source tags
# Config key: capability_source_patterns (file globs to scan)
# Config key: capability_source_tag (regex pattern, default: CAPABILITY-SOURCE:)

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

mkdir -p "$RESULTS_DIR"

yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

yaml_get_array() {
  local file="$1" key="$2"
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "D-5: Capability source annotation scan"

# Detect changed files
if [ -n "${BASE_REF:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

# Read scan patterns from config
SCAN_PATTERNS=$(yaml_get_array "$CONFIG_FILE" "capability_source_patterns")
TAG_PATTERN=$(yaml_get "$CONFIG_FILE" "capability_source_tag" "CAPABILITY-SOURCE:")

if [ -z "$SCAN_PATTERNS" ]; then
  # Default: check architecture docs
  SCAN_PATTERNS="**/ARCHITECTURE*.md
**/TECH-SELECTION*.md
**/ADR-*.md"
  echo "Using default scan patterns"
fi

PASSED=true
ISSUES=()
SCANNED=0

# For each changed file, check if it matches scan patterns
while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue

  MATCHES=false
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # Simple glob match using bash
    if [[ "$file" == $pattern ]] || [[ "$file" == *"$(basename "$pattern")" ]]; then
      MATCHES=true
      break
    fi
  done <<< "$SCAN_PATTERNS"

  if [ "$MATCHES" = true ]; then
    SCANNED=$((SCANNED + 1))
    if grep -q "$TAG_PATTERN" "$file" 2>/dev/null; then
      echo "✓ $file has capability source annotation"
    else
      ISSUES+=("$file: missing $TAG_PATTERN annotation")
      PASSED=false
      echo "✗ $file: missing capability source annotation"
    fi
  fi
done <<< "$CHANGED_FILES"

if [ $SCANNED -eq 0 ]; then
  echo "No matching architecture docs in changed files — PASS"
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d5-capability-source.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-5",
  "check_name": "Capability Source",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "files_scanned": $SCANNED,
  "issues": $(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}"; fi | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-5 Capability source annotation check failed"
  exit 1
fi

echo "✓ D-5 PASS"
exit 0
