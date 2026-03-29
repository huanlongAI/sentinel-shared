#!/bin/bash
set -euo pipefail

# Verdict Aggregation
# Dynamically detects all d*.json files in RESULTS_DIR

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

echo "Verdict Aggregation"
echo "Results directory: $RESULTS_DIR"

# Find all d*-*.json files in results directory
RESULT_FILES=$(find "$RESULTS_DIR" -maxdepth 1 -name "d*-*.json" -type f | sort)

if [ -z "$RESULT_FILES" ]; then
  echo "No result files found in $RESULTS_DIR"
  exit 1
fi

echo "Found result files:"
echo "$RESULT_FILES" | while read -r file; do
  echo "  - $(basename "$file")"
done

# Initialize aggregation
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
ALL_ISSUES=()
ALL_RESULTS=()

# Process each result file
while IFS= read -r result_file; do
  [ -z "$result_file" ] && continue

  echo "Processing: $(basename "$result_file")"

  if [ ! -f "$result_file" ]; then
    echo "  Warning: File not readable"
    continue
  fi

  # Parse JSON result
  check_id=$(jq -r '.check_id // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
  check_name=$(jq -r '.check_name // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
  passed=$(jq -r '.passed // false' "$result_file" 2>/dev/null || echo "false")

  echo "  Check: $check_id - $check_name"
  echo "  Passed: $passed"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  if [ "$passed" = "true" ]; then
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
  else
    FAILED_CHECKS=$((FAILED_CHECKS + 1))

    # Extract issues
    issues=$(jq -r '.issues[]? // .violations[]? // empty' "$result_file" 2>/dev/null || true)
    while IFS= read -r issue; do
      [ -z "$issue" ] && continue
      ALL_ISSUES+=("[$check_id] $issue")
    done <<< "$issues"
  fi

  # Collect result object
  ALL_RESULTS+=($(jq . "$result_file" 2>/dev/null || echo "{}"))

done <<< "$RESULT_FILES"

# Determine overall pass/fail
OVERALL_PASSED=true
if [ $FAILED_CHECKS -gt 0 ]; then
  OVERALL_PASSED=false
fi

# Build results array JSON
RESULTS_ARRAY="["
first=true
while IFS= read -r result_file; do
  [ -z "$result_file" ] && continue

  if [ "$first" = true ]; then
    first=false
  else
    RESULTS_ARRAY="$RESULTS_ARRAY,"
  fi

  RESULTS_ARRAY="$RESULTS_ARRAY$(jq . "$result_file" 2>/dev/null || echo "{}")"
done <<< "$RESULT_FILES"
RESULTS_ARRAY="$RESULTS_ARRAY]"

# Generate aggregated result JSON
AGGREGATE_FILE="$RESULTS_DIR/aggregate.json"
cat > "$AGGREGATE_FILE" <<EOF
{
  "verdict": {
    "overall_passed": $([[ "$OVERALL_PASSED" == true ]] && echo "true" || echo "false"),
    "total_checks": $TOTAL_CHECKS,
    "passed": $PASSED_CHECKS,
    "failed": $FAILED_CHECKS,
    "pass_rate": $(echo "scale=2; $PASSED_CHECKS * 100 / $TOTAL_CHECKS" | bc 2>/dev/null || echo "0")
  },
  "issues": $(printf '%s\n' "${ALL_ISSUES[@]}" | jq -R . | jq -s .),
  "results": $RESULTS_ARRAY,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "Aggregated Verdict:"
echo "  Overall: $([[ "$OVERALL_PASSED" == true ]] && echo "PASSED" || echo "FAILED")"
echo "  $PASSED_CHECKS/$TOTAL_CHECKS checks passed"

if [ ${#ALL_ISSUES[@]} -gt 0 ]; then
  echo "  Issues found:"
  printf '%s\n' "${ALL_ISSUES[@]}" | head -10 | while read -r issue; do
    echo "    - $issue"
  done
  if [ ${#ALL_ISSUES[@]} -gt 10 ]; then
    echo "    ... and $((${#ALL_ISSUES[@]} - 10)) more"
  fi
fi

echo ""
echo "Result written to $AGGREGATE_FILE"

# Output GitHub Actions annotation
if [ "$OVERALL_PASSED" = false ]; then
  echo "::error::Sentinel verdict FAILED: $FAILED_CHECKS check(s) failed"
  exit 1
else
  echo "::notice::Sentinel verdict PASSED: all checks successful"
  exit 0
fi
