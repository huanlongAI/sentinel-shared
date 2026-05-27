#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_SYNC_WORKFLOW="$ROOT_DIR/.github/workflows/caller-sync.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -q '\${{ inputs\.dry_run || '\''true'\'' }}' "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync must not coerce boolean false dry_run input back to true"
fi

count="$(grep -c "github.event.inputs.dry_run || 'true'" "$CALLER_SYNC_WORKFLOW" || true)"
if [ "$count" -ne 2 ]; then
  fail "caller-sync should default scheduled runs to dry_run=true while preserving workflow_dispatch dry_run=false"
fi

for expected in \
  'FAILED=""' \
  'failed_count=' \
  'head=huanlongAI:sentinel-caller-sync' \
  'File update failed' \
  'exit 1'
do
  grep -q "$expected" "$CALLER_SYNC_WORKFLOW" \
    || fail "caller-sync workflow missing failure-handling marker: $expected"
done

echo "caller-sync dry_run input handling test passed"
