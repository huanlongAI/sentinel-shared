#!/bin/bash
set -euo pipefail

# ============================================================================
# Escalation Handler v2 -- Severity Grading + Structured Output
# Routes verdicts to GitHub Actions annotations + structured JSON for
# downstream consumers (Super-Founder FeishuCardBuilder via workflow_run)
#
# Severity Model:
#   P0 (critical) -- all D-checks fail OR LLM FAIL on governance repo
#   P1 (warning)  -- some D-checks fail OR LLM WARN
#   P2 (info)     -- single non-critical check fail
#   P3 (noise)    -- LLM low-confidence PASS, no action needed
# ============================================================================

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
REPO_NAME="${GITHUB_REPOSITORY:-unknown}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-0}"

mkdir -p "$RESULTS_DIR"

# --- YAML helpers (no yq dependency) ---
yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^\s*${key}:" "$file" 2>/dev/null | head -1 \
    | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

yaml_get_nested() {
  local file="$1" parent="$2" child="$3" default="${4:-}"
  local val
  val=$(sed -n "/^\s*${parent}:/,/^\s*[a-z_]*:/p" "$file" 2>/dev/null \
    | grep -E "^\s+${child}:" | head -1 \
    | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | tr -d '"' | tr -d "'")
  echo "${val:-$default}"
}

echo "=== Escalation Handler v2 ==="

# --- Read aggregate result ---
AGGREGATE_FILE="$RESULTS_DIR/aggregate.json"
if [ ! -f "$AGGREGATE_FILE" ]; then
  echo "No aggregate result found. Run aggregate.sh first."
  exit 1
fi

OVERALL_PASSED=$(jq -r 'if .verdict.overall_passed == null then "false" else (.verdict.overall_passed | tostring) end' "$AGGREGATE_FILE" 2>/dev/null || echo "false")
TOTAL_CHECKS=$(jq -r '.verdict.total_checks // 0' "$AGGREGATE_FILE" 2>/dev/null || echo "0")
FAILED_CHECKS=$(jq -r '.verdict.failed // 0' "$AGGREGATE_FILE" 2>/dev/null || echo "0")
PASSED_CHECKS=$(jq -r '.verdict.passed // 0' "$AGGREGATE_FILE" 2>/dev/null || echo "0")

# --- Collect failed dimension IDs ---
FAILED_DIMS=()
for result_file in "$RESULTS_DIR"/d*-*.json; do
  [ -f "$result_file" ] || continue
  passed=$(jq -r 'if .passed == null then "true" else (.passed | tostring) end' "$result_file" 2>/dev/null || echo "true")
  if [ "$passed" = "false" ]; then
    check_id=$(jq -r '.check_id // "unknown"' "$result_file" 2>/dev/null || echo "unknown")
    FAILED_DIMS+=("$check_id")
  fi
done

# --- Check LLM review result if exists ---
LLM_VERDICT="none"
LLM_FAILED_CHECKS=()
LLM_FILE="$RESULTS_DIR/llm-review.json"
if [ -f "$LLM_FILE" ]; then
  LLM_VERDICT=$(jq -r '.verdict // "none"' "$LLM_FILE" 2>/dev/null || echo "none")
  # Collect LLM checks that are FAIL or WARN
  while IFS= read -r check_entry; do
    [ -z "$check_entry" ] && continue
    FAILED_DIMS+=("LLM:${check_entry}")
  done < <(jq -r '.checks // {} | to_entries[] | select(.value.verdict == "FAIL" or .value.verdict == "WARN") | .key' "$LLM_FILE" 2>/dev/null || true)
fi

# --- Read repo type from config ---
REPO_TYPE=$(yaml_get "$CONFIG_FILE" "repo_type" "unknown")

# --- Read severity overrides ---
# escalation.severity_override in config can elevate specific checks
# For now, governance repos with D-1 or LLM:GPC-003 failure = auto P0

# --- Compute Severity ---
SEVERITY="P3"

if [ "$OVERALL_PASSED" = "true" ]; then
  # All checks passed
  if [ "$LLM_VERDICT" = "WARN" ]; then
    SEVERITY="P3"  # LLM warned but D-checks all pass -- noise
  else
    SEVERITY="P3"
  fi
else
  # Something failed
  if [ "$FAILED_CHECKS" -eq "$TOTAL_CHECKS" ] && [ "$TOTAL_CHECKS" -gt 0 ]; then
    # ALL checks failed
    SEVERITY="P0"
  elif [ "$REPO_TYPE" = "governance" ]; then
    # Governance repo: any LLM FAIL or D-1 failure = P0
    IS_P0=false
    for dim in "${FAILED_DIMS[@]+"${FAILED_DIMS[@]}"}"; do
      case "$dim" in
        D-1|LLM:GPC-003|LLM:SAC-004) IS_P0=true ;;
      esac
    done
    if [ "$IS_P0" = true ]; then
      SEVERITY="P0"
    else
      SEVERITY="P1"
    fi
  elif [ "$FAILED_CHECKS" -gt 1 ]; then
    SEVERITY="P1"
  else
    SEVERITY="P2"
  fi

  # LLM FAIL on any repo type elevates to at least P1
  if [ "$LLM_VERDICT" = "FAIL" ] && [ "$SEVERITY" != "P0" ]; then
    SEVERITY="P1"
  fi
fi

echo "Repo: $REPO_NAME"
echo "Repo type: $REPO_TYPE"
echo "Verdict: passed=$OVERALL_PASSED, $PASSED_CHECKS/$TOTAL_CHECKS passed"
echo "Severity: $SEVERITY"
echo "Failed dimensions: ${FAILED_DIMS[*]:-none}"

# --- Build structured JSON for downstream consumers ---
# This JSON is embedded in GITHUB_STEP_SUMMARY for Super-Founder to parse
# from workflow_run event payload (via check_suite / jobs API)
FAILED_DIMS_JSON="[]"
if [ ${#FAILED_DIMS[@]} -gt 0 ]; then
  FAILED_DIMS_JSON=$(printf '%s\n' "${FAILED_DIMS[@]}" | jq -R . | jq -s .)
fi

SENTINEL_JSON=$(jq -n \
  --arg severity "$SEVERITY" \
  --arg repo "$REPO_NAME" \
  --arg repo_type "$REPO_TYPE" \
  --argjson total "$TOTAL_CHECKS" \
  --argjson failed "$FAILED_CHECKS" \
  --argjson passed "$PASSED_CHECKS" \
  --argjson failed_dims "$FAILED_DIMS_JSON" \
  --arg llm_verdict "$LLM_VERDICT" \
  --arg run_url "$RUN_URL" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    sentinel_severity: $severity,
    repo: $repo,
    repo_type: $repo_type,
    total_checks: $total,
    failed_checks: $failed,
    passed_checks: $passed,
    failed_dimensions: $failed_dims,
    llm_verdict: $llm_verdict,
    run_url: $run_url,
    timestamp: $ts
  }')

# --- Write structured result to file ---
ESCALATION_FILE="$RESULTS_DIR/escalation.json"
echo "$SENTINEL_JSON" > "$ESCALATION_FILE"
echo "Escalation record written to $ESCALATION_FILE"

# --- Emit to GITHUB_STEP_SUMMARY with parseable marker ---
# Super-Founder FeishuCardBuilder parses content between these markers
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo ""
    echo "<!-- SENTINEL_ESCALATION_BEGIN -->"
    echo '```json'
    echo "$SENTINEL_JSON"
    echo '```'
    echo "<!-- SENTINEL_ESCALATION_END -->"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi

# --- GitHub Actions annotations based on severity ---
case "$SEVERITY" in
  P0)
    echo "::error::[$SEVERITY] Sentinel CRITICAL: $FAILED_CHECKS/$TOTAL_CHECKS checks failed on $REPO_TYPE repo [${FAILED_DIMS[*]:-}]"
    ;;
  P1)
    echo "::warning::[$SEVERITY] Sentinel WARNING: $FAILED_CHECKS/$TOTAL_CHECKS checks failed [${FAILED_DIMS[*]:-}]"
    ;;
  P2)
    echo "::warning::[$SEVERITY] Sentinel NOTICE: $FAILED_CHECKS/$TOTAL_CHECKS checks failed [${FAILED_DIMS[*]:-}]"
    ;;
  P3)
    echo "::notice::[$SEVERITY] Sentinel PASSED: all checks successful"
    ;;
esac

# --- Exit code: P0/P1 = fail the CI step, P2/P3 = pass ---
if [ "$SEVERITY" = "P0" ] || [ "$SEVERITY" = "P1" ]; then
  exit 1
else
  exit 0
fi
