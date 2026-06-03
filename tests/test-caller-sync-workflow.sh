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

if grep -q "default: 'true'" "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync dry_run boolean input default must stay boolean true, not string 'true'"
fi

if grep -q "default: 'false'" "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync canonical skip_llm boolean input default must stay boolean false, not string 'false'"
fi

count="$(grep -c "github.event.inputs.dry_run || 'true'" "$CALLER_SYNC_WORKFLOW" || true)"
if [ "$count" -ne 2 ]; then
  fail "caller-sync should default scheduled runs to dry_run=true while preserving workflow_dispatch dry_run=false"
fi

if grep -q 'Open sync PR already exists for ${REPO}, skipping.' "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync must refresh existing sentinel-caller-sync PR branches instead of skipping them"
fi

for expected in \
  'FAILED=""' \
  'failed_count=' \
  'head=huanlongAI:sentinel-caller-sync' \
  'EXISTING_PR_NUMBER=' \
  'EXISTING_PR_AUTOSYNC=' \
  'existing_pr_not_autosync' \
  'REFRESH_REF_RESULT=' \
  'Branch refresh failed' \
  'Existing sync PR refreshed' \
  'force: true' \
  'File update failed' \
  'exit 1'
do
  grep -q "$expected" "$CALLER_SYNC_WORKFLOW" \
    || fail "caller-sync workflow missing failure-handling marker: $expected"
done

echo "caller-sync dry_run input handling test passed"
