#!/bin/bash
set -euo pipefail

# D-3: Cascade integrity
# Reads cascade rules from .sentinel/config.yaml

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$RESULTS_DIR"

# YAML/policy helpers (no yq dependency)
# shellcheck source=scripts/policy-loader.sh
source "$SCRIPT_DIR/policy-loader.sh"

echo "D-3: Cascade integrity"

# Read cascade rules from policy_file when present, otherwise config
CASCADE_MAP=$(sentinel_governance_get_map "$CONFIG_FILE" "cascade_map")

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
