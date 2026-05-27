#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_WORKFLOW="$ROOT_DIR/.github/workflows/dashboard.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'actions/workflows/consistency-sentinel.yml/runs?branch=main' "$DASHBOARD_WORKFLOW" \
  || fail "dashboard must query the Consistency Sentinel workflow-specific runs endpoint"

if grep -q 'actions/runs?per_page=5&branch=main' "$DASHBOARD_WORKFLOW"; then
  fail "dashboard must not infer Sentinel status from only the repository's latest 5 action runs"
fi

echo "dashboard workflow status query test passed"
