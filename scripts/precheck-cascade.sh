#!/bin/bash
set -euo pipefail

# D-3: Cascade integrity
# Reads cascade rules from .sentinel/config.yaml

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

mkdir -p "$RESULTS_DIR"

# YAML value reader (no yq dependency)
yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

# Parse nested YAML cascade_map into key=value pairs
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
  echo "No cascade rules configured — PASS"
  cat > "$RESULTS_DIR/d3-cascade.json" <<EOF
{"check_id":"D-3","check_name":"Cascade Integrity","passed":true,"issues":[],"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

echo "Cascade rules found:"
echo "$CASCADE_MAP" | while read -r rule; do
  echo "  $rule"
done

# Initialize result
PASSED=true
ISSUES=()

# Detect changed files: PR diff or push commit diff
if [ -n "${BASE_REF:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files to check — PASS"
else
  # Check cascade rules
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    # Parse source=target
    source="${rule%=*}"
    target="${rule#*=}"

    # Check if source file was modified
    if echo "$CHANGED_FILES" | grep -q "^${source}$"; then
      # Verify target also exists and check if it needs update
      if [ ! -f "$target" ]; then
        ISSUES+=("Cascade rule violation: $source modified but target $target does not exist")
        PASSED=false
        echo "✗ Target $target does not exist for source $source"
      else
        echo "✓ Cascade rule verified: $source -> $target"
        # Optionally verify target was also modified
        if ! echo "$CHANGED_FILES" | grep -q "^${target}$"; then
          echo "⚠ Source $source modified but target $target not changed (may be intentional)"
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
  "issues": $(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .; else echo '[]'; fi),
  "rules_checked": $(echo "$CASCADE_MAP" | wc -l),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-3 Cascade integrity check failed"
  exit 1
fi

echo "✓ D-3 PASS"
exit 0
