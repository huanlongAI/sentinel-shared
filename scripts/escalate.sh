#!/bin/bash
set -euo pipefail

# Escalation Handler
# Routes verdicts and issues to appropriate channels

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
  sed -n "/^\s*${key}:/,/^\s*[a-z]/p" "$file" 2>/dev/null | { grep "^\s*-" || true; } | sed 's/^\s*-\s*//' | tr -d '"' | tr -d "'"
}

echo "Escalation Handler"

# Read aggregate result
AGGREGATE_FILE="$RESULTS_DIR/aggregate.json"

if [ ! -f "$AGGREGATE_FILE" ]; then
  echo "No aggregate result found. Run aggregate.sh first."
  exit 1
fi

# Parse aggregate result
OVERALL_PASSED=$(jq -r '.verdict.overall_passed // false' "$AGGREGATE_FILE" 2>/dev/null || echo "false")
TOTAL_CHECKS=$(jq -r '.verdict.total_checks // 0' "$AGGREGATE_FILE" 2>/dev/null || echo "0")
FAILED_CHECKS=$(jq -r '.verdict.failed // 0' "$AGGREGATE_FILE" 2>/dev/null || echo "0")
ISSUES=$(jq -r '.issues[]? // empty' "$AGGREGATE_FILE" 2>/dev/null || true)

echo "Aggregate Verdict: $OVERALL_PASSED"
echo "Total checks: $TOTAL_CHECKS"
echo "Failed checks: $FAILED_CHECKS"

# Read escalation configuration
ESCALATION_ENABLED=$(yaml_get "$CONFIG_FILE" "escalation.enabled" "false")
ESCALATION_CHANNEL=$(yaml_get "$CONFIG_FILE" "escalation.channel" "github")
ESCALATION_LEVEL=$(yaml_get "$CONFIG_FILE" "escalation.level" "warning")

echo "Escalation config:"
echo "  Enabled: $ESCALATION_ENABLED"
echo "  Channel: $ESCALATION_CHANNEL"
echo "  Level: $ESCALATION_LEVEL"

# Escalate based on verdict
if [ "$OVERALL_PASSED" = "false" ]; then
  # Build escalation message
  MESSAGE="Sentinel check failed"
  MESSAGE="$MESSAGE - $FAILED_CHECKS/$TOTAL_CHECKS checks failed"

  # Add issue details if available
  ISSUE_COUNT=$(echo "$ISSUES" | grep -c . || true)
  if [ $ISSUE_COUNT -gt 0 ]; then
    MESSAGE="$MESSAGE ($ISSUE_COUNT issues)"
  fi

  # Output GitHub Actions annotations based on severity
  case "$ESCALATION_LEVEL" in
    error)
      echo "::error::$MESSAGE"
      ;;
    warning)
      echo "::warning::$MESSAGE"
      ;;
    notice)
      echo "::notice::$MESSAGE"
      ;;
    *)
      echo "::warning::$MESSAGE"
      ;;
  esac

  # Additional escalation channels can be implemented here
  if [ "$ESCALATION_CHANNEL" = "slack" ]; then
    echo "Slack escalation would be sent here (not yet implemented)"
  elif [ "$ESCALATION_CHANNEL" = "email" ]; then
    echo "Email escalation would be sent here (not yet implemented)"
  fi

  # Create escalation record
  ESCALATION_FILE="$RESULTS_DIR/escalation.json"
  cat > "$ESCALATION_FILE" <<EOF
{
  "escalation_id": "esc-$(date +%s)",
  "status": "escalated",
  "severity": "$ESCALATION_LEVEL",
  "channel": "$ESCALATION_CHANNEL",
  "message": "$MESSAGE",
  "failed_checks": $FAILED_CHECKS,
  "total_checks": $TOTAL_CHECKS,
  "issues_found": $ISSUE_COUNT,
  "aggregate_file": "$AGGREGATE_FILE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  echo "Escalation record written to $ESCALATION_FILE"
  exit 1

else
  echo "✓ Verdict PASSED - no escalation needed"

  # Create success record
  ESCALATION_FILE="$RESULTS_DIR/escalation.json"
  cat > "$ESCALATION_FILE" <<EOF
{
  "escalation_id": "esc-$(date +%s)",
  "status": "passed",
  "severity": "none",
  "channel": "$ESCALATION_CHANNEL",
  "message": "All checks passed",
  "failed_checks": 0,
  "total_checks": $TOTAL_CHECKS,
  "issues_found": 0,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  exit 0
fi
