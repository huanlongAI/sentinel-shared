#!/bin/bash
set -euo pipefail

# D-2: Terminology scan
# Reads forbidden terms from .sentinel/config.yaml

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

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

echo "D-2: Terminology scan"

# Read forbidden terms from config
FORBIDDEN_TERMS=$(yaml_get_array "$CONFIG_FILE" "forbidden_terms")

# Use defaults if not configured
if [ -z "$FORBIDDEN_TERMS" ]; then
  FORBIDDEN_TERMS=$(cat <<'EOF'
TODO
FIXME
HACK
XXX
BUG
TEMP
DEPRECATED
UNUSED
EOF
)
  echo "Using default forbidden terms"
else
  echo "Read forbidden terms from config"
fi

# Initialize result
PASSED=true
ISSUES=()
VIOLATIONS=()

# Get staged files
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")

if [ -z "$STAGED_FILES" ]; then
  echo "No staged files found"
  PASSED=true
else
  # Check each staged file for forbidden terms
  while IFS= read -r file; do
    # Skip binary files
    if file "$file" | grep -q "binary"; then
      continue
    fi

    # Check each forbidden term
    while IFS= read -r term; do
      [ -z "$term" ] && continue

      # Search for term in the file (case insensitive)
      if grep -in "$term" "$file" > /dev/null 2>&1; then
        # Get line numbers and context
        matches=$(grep -in "$term" "$file" | head -5)
        VIOLATIONS+=("$file: contains forbidden term '$term'")
        PASSED=false
      fi
    done <<< "$FORBIDDEN_TERMS"
  done <<< "$STAGED_FILES"
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
