#!/bin/bash
set -euo pipefail

# D-2: Terminology scan
# Reads forbidden terms from policy_file when present, otherwise .sentinel/config.yaml
# Supports terminology_exclude_patterns to skip governance spec files

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$RESULTS_DIR"

# YAML/policy helpers (no yq dependency)
# shellcheck source=scripts/policy-loader.sh
source "$SCRIPT_DIR/policy-loader.sh"

echo "D-2: Terminology scan"

# Read forbidden terms from policy_file when present, otherwise config
FORBIDDEN_TERMS_SOURCE_FILE=$(sentinel_governance_source_file "$CONFIG_FILE" "forbidden_terms")
FORBIDDEN_TERMS=$(sentinel_yaml_get_array "$FORBIDDEN_TERMS_SOURCE_FILE" "forbidden_terms")

display_repo_relative_path() {
  local path="$1"
  local repo_root repo_root_real
  repo_root=$(sentinel_repo_root)
  repo_root_real=$(sentinel_realpath "$repo_root" 2>/dev/null || echo "$repo_root")

  case "$path" in
    "$repo_root"/*) echo "${path#"$repo_root"/}" ;;
    "$repo_root_real"/*) echo "${path#"$repo_root_real"/}" ;;
    *) echo "$path" ;;
  esac
}

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
  if [ "$FORBIDDEN_TERMS_SOURCE_FILE" = "$CONFIG_FILE" ]; then
    echo "Read forbidden terms from config"
  else
    echo "Read forbidden terms from policy_file: $(display_repo_relative_path "$FORBIDDEN_TERMS_SOURCE_FILE")"
  fi
fi

# Read exclude patterns from policy_file when present, otherwise config
EXCLUDE_PATTERNS=$(sentinel_governance_get_array "$CONFIG_FILE" "terminology_exclude_patterns")
if [ -n "$EXCLUDE_PATTERNS" ]; then
  echo "Exclude patterns loaded: $(echo "$EXCLUDE_PATTERNS" | wc -l | tr -d ' ') patterns"
fi

# Function: check if a filename matches any exclude pattern
should_exclude() {
  local filepath="$1"
  local basename normalized_path normalized_pattern
  basename=$(basename "$filepath")
  normalized_path="${filepath#./}"
  
  if [ -z "$EXCLUDE_PATTERNS" ]; then
    return 1  # no patterns = don't exclude
  fi
  
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    normalized_pattern="${pattern#./}"
    # Use bash pattern matching (supports * and ? globs)
    # Match repository-relative paths first for path-aware excludes.
    # shellcheck disable=SC2254
    case "$normalized_path" in
      $normalized_pattern) return 0 ;;  # path match = exclude
    esac
    # Preserve legacy basename-style patterns.
    # shellcheck disable=SC2254
    case "$basename" in
      $pattern) return 0 ;;  # match = exclude
    esac
  done <<< "$EXCLUDE_PATTERNS"
  
  return 1  # no match = don't exclude
}

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
  FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
  echo "Scanning $FILE_COUNT changed files"
  EXCLUDED_COUNT=0
  # Check each changed file for forbidden terms
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ ! -f "$file" ] && continue
    # Skip excluded files (governance specs that discuss forbidden terms)
    if should_exclude "$file"; then
      EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
      continue
    fi
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
  if [ $EXCLUDED_COUNT -gt 0 ]; then
    echo "Excluded $EXCLUDED_COUNT files by terminology_exclude_patterns"
  fi
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
  "violations": $(if [ ${#VIOLATIONS[@]} -gt 0 ]; then printf '%s\n' "${VIOLATIONS[@]}" | jq -R . | jq -s .; else echo '[]'; fi),
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
