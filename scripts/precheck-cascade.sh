#!/bin/bash
set -euo pipefail

# D-3: Cascade integrity
# Reads cascade rules from .sentinel/config.yaml

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

# Parse nested YAML cascade_map into key=value pairs
# Expects format:
# cascade_map:
#   src/module_a: src/module_b
#   src/module_b: src/module_c
parse_cascade_map() {
  local file="$1"
  sed -n "/^\s*cascade_map:/,/^\s*[a-z]/p" "$file" 2>/dev/null | \
    { grep -E "^\s+[^ :]+:\s+" || true; } | \
    sed 's/^\s*//' | \
    sed 's/:\s*/=/'
}

echo "D-3: Cascade integrity"

# Read cascade rules from config
CASCADE_MAP=$(parse_cascade_map "$CONFIG_FILE")

if [ -z "$CASCADE_MAP" ]; then
  echo "No cascade rules configured"
  echo "{}"> "$RESULTS_DIR/d3-cascade.json"
  exit 0
fi

echo "Cascade rules found:"
echo "$CASCADE_MAP" | while read -r rule; do
  echo "  $rule"
done

# Initialize result
PASSED=true
ISSUES=()

# Get list of modified files
MODIFIED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")

if [ -z "$MODIFIED_FILES" ]; then
  echo "No modified files to check"
else
  # Check cascade rules
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue

    # Parse source=target
    source="${rule%=*}"
    target="${rule#*=}"

    # Check if source file was modified
    if echo "$MODIFIED_FILES" | grep -q "^${source}$"; then
      # Verify target also exists and check if it needs update
      if [ ! -f "$target" ]; then
        ISSUES+=("Cascade rule violation: $source modified but target $target does not exist")
        PASSED=false
        echo "✗ Target $target does not exist for source $source"
      else
        echo "✓ Cascade rule verified: $source -> $target"

        # Optionally verify target was also modified
        if ! echo "$MODIFIED_FILES" | grep -q "^${target}$"; then
          echo "⚠ Source $source modified but target $target not staged (may be intentional)"
        fi
      fi
    fi
  done <<< "$CASCADE_MAP"
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d3-cascade.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-3",
  "check_name": "Cascade Integrity",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "issues": $(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}"; fi | jq -R . | jq -s .),
  "rules_checked": $(echo "$CASCADE_MAP" | wc -l),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-3 Cascade integrity check failed"
  exit 1
fi

exit 0
