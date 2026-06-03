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

REQUIRED_RESULT_FILES="${REQUIRED_RESULT_FILES:-d1-changelog.json d2-terminology.json d3-cascade.json d4-directory.json d5-capability-source.json d6-brand-token.json}"
if [ -n "$REQUIRED_RESULT_FILES" ]; then
  for required_result in $REQUIRED_RESULT_FILES; do
    [ -z "$required_result" ] && continue
    if [ ! -f "$RESULTS_DIR/$required_result" ]; then
      echo "::error::Required sentinel result missing: $required_result"
      jq -n \
        --arg file "$required_result" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          check_id: "D-MISSING",
          check_name: "Missing Result",
          passed: false,
          status: "missing",
          issues: ["Required sentinel result file missing: " + $file],
          timestamp: $timestamp
        }' > "$RESULTS_DIR/$required_result"
    fi
  done
fi

# Find deterministic check files plus optional LLM review result.
RESULT_FILES=$(find "$RESULTS_DIR" -maxdepth 1 \( -name "d*-*.json" -o -name "llm-review.json" \) -type f | sort)
OWNER_OVERRIDE_FILE="$RESULTS_DIR/owner-reviewed-override.json"
OWNER_OVERRIDE_ACTIVE=false
OWNER_OVERRIDE_JSON="null"
if [ -f "$OWNER_OVERRIDE_FILE" ] && jq -e '
  .passed == true
  and .overrides_review_id == "llm-review"
  and .overrides_verdict == "ESCALATE"
' "$OWNER_OVERRIDE_FILE" >/dev/null 2>&1; then
  OWNER_OVERRIDE_ACTIVE=true
  OWNER_OVERRIDE_JSON=$(jq . "$OWNER_OVERRIDE_FILE")
fi

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
ESCALATE_CHECKS=0
OWNER_REVIEWED_OVERRIDES=0
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
  check_id=$(jq -r '.check_id // .review_id // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
  check_name=$(jq -r '.check_name // (if (.review_id // "") == "llm-review" then "LLM Review" else "unknown" end)' "$result_file" 2>/dev/null || echo "unknown")
  passed=$(jq -r '.passed // false' "$result_file" 2>/dev/null || echo "false")
  effective_passed="$passed"
  owner_reviewed=false
  result_verdict=$(jq -r '.verdict // ""' "$result_file" 2>/dev/null || echo "")

  if [ "$check_id" = "llm-review" ] \
    && [ "$passed" != "true" ] \
    && [ "$result_verdict" = "ESCALATE" ] \
    && [ "$OWNER_OVERRIDE_ACTIVE" = true ]; then
    effective_passed=true
    owner_reviewed=true
    OWNER_REVIEWED_OVERRIDES=$((OWNER_REVIEWED_OVERRIDES + 1))
  fi

  echo "  Check: $check_id - $check_name"
  echo "  Passed: $passed"
  if [ "$owner_reviewed" = true ]; then
    echo "  Owner-reviewed override: true"
  fi

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  if [ "$effective_passed" = "true" ]; then
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
  else
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    if [ "$check_id" = "llm-review" ] && [ "$result_verdict" = "ESCALATE" ]; then
      ESCALATE_CHECKS=$((ESCALATE_CHECKS + 1))
    fi

    # Extract issues
    issues=$(jq -r '([.issues[]?, .violations[]?] + (if (.reason // "") != "" then [.reason] else [] end))[]?' "$result_file" 2>/dev/null || true)
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

GATE_RESULT="PASS"
if [ "$OVERALL_PASSED" = false ]; then
  if [ "$FAILED_CHECKS" -eq "$ESCALATE_CHECKS" ] && [ "$ESCALATE_CHECKS" -gt 0 ]; then
    GATE_RESULT="ESCALATE"
  else
    GATE_RESULT="FAIL"
  fi
elif [ "$OWNER_REVIEWED_OVERRIDES" -gt 0 ]; then
  GATE_RESULT="OWNER_REVIEWED_PASS"
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

  r_id=$(jq -r '.check_id // .review_id // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
  r_pass=$(jq -r '.passed // false' "$result_file" 2>/dev/null || echo "false")
  r_verdict=$(jq -r '.verdict // ""' "$result_file" 2>/dev/null || echo "")
  if [ "$r_id" = "llm-review" ] \
    && [ "$r_pass" != "true" ] \
    && [ "$r_verdict" = "ESCALATE" ] \
    && [ "$OWNER_OVERRIDE_ACTIVE" = true ]; then
    RESULTS_ARRAY="$RESULTS_ARRAY$(jq --slurpfile owner "$OWNER_OVERRIDE_FILE" '. + {effective_passed: true, owner_reviewed_override: $owner[0]}' "$result_file" 2>/dev/null || echo "{}")"
  else
    RESULTS_ARRAY="$RESULTS_ARRAY$(jq . "$result_file" 2>/dev/null || echo "{}")"
  fi
done <<< "$RESULT_FILES"
RESULTS_ARRAY="$RESULTS_ARRAY]"

# Generate aggregated result JSON
AGGREGATE_FILE="$RESULTS_DIR/aggregate.json"
cat > "$AGGREGATE_FILE" <<EOF
{
  "verdict": {
    "overall_passed": $([[ "$OVERALL_PASSED" == true ]] && echo "true" || echo "false"),
    "gate_result": "$GATE_RESULT",
    "total_checks": $TOTAL_CHECKS,
    "passed": $PASSED_CHECKS,
    "failed": $FAILED_CHECKS,
    "escalate": $ESCALATE_CHECKS,
    "owner_reviewed_overrides": $OWNER_REVIEWED_OVERRIDES,
    "pass_rate": $(echo "scale=2; $PASSED_CHECKS * 100 / $TOTAL_CHECKS" | bc 2>/dev/null || echo "0")
  },
  "issues": $(if [ ${#ALL_ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ALL_ISSUES[@]}" | jq -R . | jq -s .; else echo '[]'; fi),
  "owner_reviewed_override": $OWNER_OVERRIDE_JSON,
  "results": $RESULTS_ARRAY,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "Aggregated Verdict:"
echo "  Overall: $GATE_RESULT"
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

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "gate_result=$GATE_RESULT"
    echo "overall_passed=$OVERALL_PASSED"
    echo "failed_checks=$FAILED_CHECKS"
    echo "owner_reviewed_overrides=$OWNER_REVIEWED_OVERRIDES"
  } >> "$GITHUB_OUTPUT"
fi

# ── Generate sentinel-report.md ──
REPORT_FILE="$RESULTS_DIR/sentinel-report.md"
{
  echo "### Consistency Sentinel"
  echo ""
  if [ "$GATE_RESULT" = "OWNER_REVIEWED_PASS" ]; then
    echo "**判定**: OWNER_REVIEWED_PASS ✅"
  elif [ "$OVERALL_PASSED" = true ]; then
    echo "**判定**: PASS ✅"
  elif [ "$GATE_RESULT" = "ESCALATE" ]; then
    echo "**判定**: ESCALATE ⚠️"
  else
    echo "**判定**: FAIL ❌"
  fi
  echo "**检查项**: ${PASSED_CHECKS}/${TOTAL_CHECKS} 通过"
  echo ""
  echo "| 检查 | 状态 | 问题 |"
  echo "|------|------|------|"

  while IFS= read -r result_file; do
    [ -z "$result_file" ] && continue
    [ ! -f "$result_file" ] && continue
    r_id=$(jq -r '.check_id // .review_id // "?"' "$result_file" 2>/dev/null || echo "?")
    r_name=$(jq -r '.check_name // (if (.review_id // "") == "llm-review" then "LLM Review" else "?" end)' "$result_file" 2>/dev/null || echo "?")
    r_pass=$(jq -r '.passed // false' "$result_file" 2>/dev/null || echo "false")
    r_verdict=$(jq -r '.verdict // ""' "$result_file" 2>/dev/null || echo "")
    r_issues=$(jq -r '([.issues[]?, .violations[]?] + (if (.reason // "") != "" then [.reason] else [] end) | join("; ")) // ""' "$result_file" 2>/dev/null || echo "")
    if [ "$r_id" = "llm-review" ] \
      && [ "$r_pass" != "true" ] \
      && [ "$r_verdict" = "ESCALATE" ] \
      && [ "$OWNER_OVERRIDE_ACTIVE" = true ]; then
      override_actor=$(jq -r '.actor // "owner"' "$OWNER_OVERRIDE_FILE" 2>/dev/null || echo "owner")
      override_url=$(jq -r '.comment_url // ""' "$OWNER_OVERRIDE_FILE" 2>/dev/null || echo "")
      if [ -n "$override_url" ]; then
        echo "| ${r_id} ${r_name} | 🟡 owner-reviewed | LLM ESCALATE accepted by ${override_actor}: ${override_url} |"
      else
        echo "| ${r_id} ${r_name} | 🟡 owner-reviewed | LLM ESCALATE accepted by ${override_actor} |"
      fi
    elif [ "$r_pass" = "true" ]; then
      echo "| ${r_id} ${r_name} | ✅ | — |"
    else
      echo "| ${r_id} ${r_name} | ❌ | ${r_issues:-见详细日志} |"
    fi
  done <<< "$RESULT_FILES"

  echo ""
  echo "> 详细日志见 Actions artifacts"
} > "$REPORT_FILE"

echo "Report written to $REPORT_FILE"

# Output GitHub Actions annotation
if [ "$OVERALL_PASSED" = false ]; then
  if [ "$GATE_RESULT" = "ESCALATE" ]; then
    echo "::error::Sentinel verdict ESCALATE: $FAILED_CHECKS check(s) require owner review"
  else
    echo "::error::Sentinel verdict FAILED: $FAILED_CHECKS check(s) failed"
  fi
  exit 1
elif [ "$GATE_RESULT" = "OWNER_REVIEWED_PASS" ]; then
  echo "::notice::Sentinel verdict OWNER_REVIEWED_PASS: LLM ESCALATE accepted by owner-reviewed evidence"
  exit 0
else
  echo "::notice::Sentinel verdict PASSED: all checks successful"
  exit 0
fi
