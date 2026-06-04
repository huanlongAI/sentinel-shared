#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_SYNC_WORKFLOW="$ROOT_DIR/.github/workflows/caller-sync.yml"
TARGETS_FILE="$ROOT_DIR/matrix/caller-target-repos.txt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$TARGETS_FILE" ] || fail "caller target repo config must exist"

if ! grep -Eq '^[A-Za-z0-9._-]+$' "$TARGETS_FILE"; then
  fail "caller target repo config must contain at least one plain repo name"
fi

if grep -q '\${{ inputs\.dry_run || '\''true'\'' }}' "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync must not coerce boolean false dry_run input back to true"
fi

if grep -q "default: 'true'" "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync dry_run boolean input default must stay boolean true, not string 'true'"
fi

if grep -q "default: 'false'" "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync canonical skip_llm boolean input default must stay boolean false, not string 'false'"
fi

grep -Fq "github.event_name == 'repository_dispatch' || fromJSON(github.event.inputs.skip_llm || 'false')" "$CALLER_SYNC_WORKFLOW" \
  || fail "caller-sync canonical template must skip LLM during sentinel-cascade repository_dispatch"

count="$(grep -c "github.event.inputs.dry_run || 'true'" "$CALLER_SYNC_WORKFLOW" || true)"
if [ "$count" -ne 2 ]; then
  fail "caller-sync should default scheduled runs to dry_run=true while preserving workflow_dispatch dry_run=false"
fi

if grep -q 'Open sync PR already exists for ${REPO}, skipping.' "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync must refresh existing sentinel-caller-sync PR branches instead of skipping them"
fi

if grep -Fq "[ '\$DRY_RUN' = 'true' ]" "$CALLER_SYNC_WORKFLOW"; then
  fail "caller-sync summary must evaluate DRY_RUN value instead of the literal string"
fi

for expected in \
  'Consistency Sentinel -- MIRA P-2 Consistency Gate' \
  'NOTE: permissions MUST be in caller, not in reusable workflow' \
  '@main reusable workflow reference is intentional for this thin caller projection.' \
  'LLM provider credentials are consumed only by sentinel-shared provider router.' \
  'HeiyuCode is preferred when configured; Anthropic remains the fallback provider.' \
  'actions/checkout@v5' \
  'TARGET_REPOS_FILE: matrix/caller-target-repos.txt' \
  'load_downstream_repos()' \
  'DOWNSTREAM_REPOS="$(load_downstream_repos)"' \
  'target_repos:' \
  'TARGET_REPOS_INPUT=' \
  'SELECTED_REPOS=' \
  'INVALID_TARGETS=' \
  'invalid_target' \
  'for REPO in $SELECTED_REPOS' \
  '[ "$DRY_RUN" = "true" ]' \
  'FAILED=""' \
  'failed_count=' \
  'head=huanlongAI:sentinel-caller-sync' \
  'EXISTING_PR_NUMBER=' \
  'EXISTING_PR_AUTOSYNC=' \
  'huanlongAI/sentinel-shared#17' \
  'startswith("chore(sentinel):")' \
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

for forbidden in \
  'DOWNSTREAM_REPOS: >-' \
  'tzhOS tzh-Harness tzh-agent-configs' \
  'hl-platform hl-framework hl-factory' \
  'hl-dispatch hl-contracts hl-console-native team-memory'
do
  if grep -Fq "$forbidden" "$CALLER_SYNC_WORKFLOW"; then
    fail "caller-sync workflow must not hardcode target repo list: $forbidden"
  fi
done

for expected in \
  'CALLER_SYNC_TOKEN_REMEDIATION=' \
  'workflow write permission' \
  'Caller sync token lacks workflow write access' \
  'GitHub API message:' \
  'token_scope'
do
  grep -Fq "$expected" "$CALLER_SYNC_WORKFLOW" \
    || fail "caller-sync workflow missing token diagnostic marker: $expected"
done

echo "caller-sync dry_run input handling test passed"
