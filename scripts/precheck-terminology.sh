#!/bin/bash
set -euo pipefail

# D-2: Terminology scan
# Reads forbidden terms from .sentinel/config.yaml

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

mkdir -p "$RESULTS_DIR"

# YAML helpers (no yq dependency)
yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

yaml_get_array() {
  local file="$1" key="$2"
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "D-2: Terminology scan"

# Read forbidden terms from config
FORBIDDEN_TERMS=$(yaml_get_array "$CONFIG_FILE" "forbidden_terms")

# Use defaults if not configured
if [ -z "$FORBIDDEN_TERMS" ]; then
  FORBIDDEN_TERMS=$(cat <<'TERMS'
TODO
FIXME
HACK
XXX
BUG
TEMP
DEPRECATED
UNUSED
TERMS
)
  echo "Using default forbidden terms"
else
  echo "Read forbidden terms from config"
fi

# Initialize result
PASSED=true
ISSUES=()
VIOLATIONS=()

# Detect changed files: PR diff or push commit diff
if [ -n "${BASE_REF:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files found — PASS"
  PASSED=true
else
  echo "Scanning $(echo "$CHANGED_FILES" | wc -l | tr -d ' ') changed files"
  # Check each changed file for forbidden terms
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ ! -f "$file" ] && continue
    # Skip binary files
    if file "$file" | grep -q "binary"; then
      continue
    fi
    # Check each forbidden term
    while IFS= read -r term; do
      [ -z "$term" ] && continue
      # Search for term in the file (case insensitive, whole word)
      if grep -inw "$term" "$file" > /dev/null 2>&1; then
        VIOLATIONS+=("$file: contains forbidden term '$term'")
        PASSED=false
      fi
    done <<< "$FORBIDDEN_TERMS"
  done <<< "$CHANGED_FILES"
fi

if [ "$PASSED" = false ]; then
  ISSUES=("${VIOLATIONS[@]}")
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d2-terminology.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-2",
  "check_name": "Terminology",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "violations": $(if [ ${#VIOLATIONS[@]} -gt 0 ]; then printf '%s\n' "${VIOLATIONS[@]}"; fi | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-2 Terminology check failed - found forbidden terms"
  exit 1
fi

echo "✓ No forbidden terms detected"
exit 0
