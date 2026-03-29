#!/bin/bash
set -euo pipefail

# D-4: Directory structure compliance (SEC-003)
# Checks that repo directory layout matches expected spec from config
# Config key: directory_spec (list of required dirs/files)

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

mkdir -p "$RESULTS_DIR"

yaml_get_array() {
  local file="$1" key="$2"
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "D-4: Directory structure compliance"

# Read required paths from config
REQUIRED_PATHS=$(yaml_get_array "$CONFIG_FILE" "directory_spec")

if [ -z "$REQUIRED_PATHS" ]; then
  echo "No directory_spec configured — SKIP"
  cat > "$RESULTS_DIR/d4-directory.json" <<EOF
{"check_id":"D-4","check_name":"Directory Structure","passed":true,"skipped":true,"issues":[],"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  exit 0
fi

PASSED=true
ISSUES=()

while IFS= read -r req_path; do
  [ -z "$req_path" ] && continue
  if [ ! -e "$req_path" ]; then
    ISSUES+=("Required path missing: $req_path")
    PASSED=false
    echo "✗ Missing: $req_path"
  else
    echo "✓ Found: $req_path"
  fi
done <<< "$REQUIRED_PATHS"

# Generate result JSON
RESULT_FILE="$RESULTS_DIR/d4-directory.json"
cat > "$RESULT_FILE" <<EOF
{
  "check_id": "D-4",
  "check_name": "Directory Structure",
  "passed": $([[ "$PASSED" == true ]] && echo "true" || echo "false"),
  "issues": $(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}"; fi | jq -R . | jq -s .),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-4 Directory structure check failed"
  exit 1
fi

echo "✓ D-4 PASS"
exit 0
