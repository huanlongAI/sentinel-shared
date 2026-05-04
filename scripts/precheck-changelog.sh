#!/bin/bash
set -euo pipefail

# D-1: CHANGELOG 留痕检查
# 规则：如果治理文件（governance_files）被修改，则必须同步更新 CHANGELOG
# 如果没有治理文件被修改，自动 PASS

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$RESULTS_DIR"

# YAML/policy helpers (no yq dependency)
# shellcheck source=scripts/policy-loader.sh
source "$SCRIPT_DIR/policy-loader.sh"

echo "D-1: CHANGELOG check"

# Detect changed files: PR diff or push commit diff
if [ -n "${BASE_REF:-}" ]; then
  CHANGED_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null || echo "")
elif git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
else
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

if [ -z "$CHANGED_FILES" ]; then
  echo "No changed files detected — PASS"
  cat > "$RESULTS_DIR/d1-changelog.json" <<EOF
{"check_id":"D-1","check_name":"CHANGELOG","passed":true,"issues":[],"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

echo "Changed files in this commit/PR:"
echo "$CHANGED_FILES" | head -20

# Read governance files list from policy_file when present, otherwise config
GOVERNANCE_FILES=$(sentinel_governance_get_array "$CONFIG_FILE" "governance_files")
if [ -z "$GOVERNANCE_FILES" ]; then
  echo "No governance_files configured — PASS"
  cat > "$RESULTS_DIR/d1-changelog.json" <<EOF
{"check_id":"D-1","check_name":"CHANGELOG","passed":true,"issues":[],"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

# Read changelog file name (default: CHANGELOG.md)
CHANGELOG_FILE=$(sentinel_yaml_get "$CONFIG_FILE" "changelog_file" "CHANGELOG.md")

# Check: did any governance file change?
MODIFIED_GOV_FILES=()
while IFS= read -r gov_file; do
  [ -z "$gov_file" ] && continue
  if echo "$CHANGED_FILES" | grep -q "^${gov_file}$"; then
    MODIFIED_GOV_FILES+=("$gov_file")
  fi
done <<< "$GOVERNANCE_FILES"

PASSED=true
ISSUES=()

if [ ${#MODIFIED_GOV_FILES[@]} -eq 0 ]; then
  echo "No governance files modified in this change — PASS"
else
  echo "Modified governance files: ${MODIFIED_GOV_FILES[*]}"
  # Check if CHANGELOG was also updated
  if echo "$CHANGED_FILES" | grep -q "^${CHANGELOG_FILE}$"; then
    echo "✓ ${CHANGELOG_FILE} was updated alongside governance changes"
  else
    # Also accept RULINGS.md update as changelog equivalent (at any path)
    if echo "$CHANGED_FILES" | grep -q "RULINGS.md$"; then
      echo "✓ RULINGS.md was updated (accepted as changelog equivalent)"
    else
      PASSED=false
      for gf in "${MODIFIED_GOV_FILES[@]}"; do
        ISSUES+=("${gf} was modified but ${CHANGELOG_FILE} was not updated")
      done
      echo "✗ Governance files changed but ${CHANGELOG_FILE} not updated"
    fi
  fi
fi

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d1-changelog.json"
ISSUES_JSON=$(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .; else echo '[]'; fi)
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-1",
  "check_name": "CHANGELOG",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "issues": ${ISSUES_JSON:-[]},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-1 CHANGELOG check failed"
  exit 1
fi

echo "✓ D-1 PASS"
exit 0
