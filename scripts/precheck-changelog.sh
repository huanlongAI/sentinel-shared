#!/bin/bash
set -euo pipefail

# D-1: CHANGELOG check
# Reads CHANGELOG patterns from .sentinel/config.yaml

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
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | grep '^\s*-' | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

# Initialize result
PASSED=true
ISSUES=()

# Read governance files from config
GOVERNANCE_FILES=$(yaml_get_array "$CONFIG_FILE" "governance_files")

if [ -z "$GOVERNANCE_FILES" ]; then
  GOVERNANCE_FILES=$(echo -e "CHANGELOG.md\nCHANGELOG.txt")
fi

echo "D-1: CHANGELOG check"
echo "Governance files: $GOVERNANCE_FILES"

# Check that at least one governance file exists and has been modified
FOUND_GOVERNANCE=false
for gov_file in $GOVERNANCE_FILES; do
  if [ -f "$gov_file" ]; then
    FOUND_GOVERNANCE=true
    if git diff --cached --name-only 2>/dev/null | grep -q "^${gov_file}$"; then
      echo "✓ Found modified $gov_file"
    else
      echo "! No changes to $gov_file in this commit"
      ISSUES+=("$gov_file has not been modified in this commit")
    fi
  fi
done

if [ "$FOUND_GOVERNANCE" = false ]; then
  PASSED=false
  ISSUES+=("No governance files found (checked: $GOVERNANCE_FILES)")
  echo "✗ No governance files found"
else
  if [ ${#ISSUES[@]} -gt 0 ]; then
    PASSED=false
  fi
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d1-changelog.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-1",
  "check_name": "CHANGELOG",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "issues": $(printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-1 CHANGELOG check failed"
  exit 1
fi

exit 0
