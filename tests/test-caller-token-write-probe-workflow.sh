#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/caller-token-write-probe.yml"
TARGET_RESOLVER="$ROOT_DIR/scripts/caller-targets.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$WORKFLOW" ] || fail "caller token write probe workflow must exist"
[ -x "$TARGET_RESOLVER" ] || fail "caller target resolver must exist"

for expected in \
  'name: Caller Token Write Probe' \
  'workflow_dispatch:' \
  'target_repo:' \
  'type: string' \
  'GH_TOKEN: ${{ secrets.CASCADE_TOKEN }}' \
  'REPO_MAP_REPO: huanlongAI/tzhOS' \
  'REPO_MAP_PATH: 40-PPR/REPO-MAP.md' \
  'REPO_MAP_REF: main' \
  'TARGET_RESOLVER: scripts/caller-targets.sh' \
  "CLEANUP: \${{ github.event.inputs.cleanup || 'true' }}" \
  'load_repo_map()' \
  'load_probe_targets()' \
  'PROBE_TARGETS="$(load_probe_targets)"' \
  'PROBE_BRANCH="${PROBE_BRANCH_PREFIX}-${RUN_ID}"' \
  'PROBE_PATH=".github/workflows/sentinel-token-write-probe-${RUN_ID}.yml"' \
  'BRANCH_CREATED="false"' \
  'write_summary()' \
  'trap cleanup_branch EXIT' \
  'BRANCH_CREATED="true"' \
  'DELETE' \
  'git/refs/heads/${PROBE_BRANCH}' \
  'CASCADE_TOKEN lacks workflow-file write access' \
  'workflow write permission' \
  'write_http_${UPDATE_RESULT}_token_scope' \
  'Invalid probe target' \
  'Probe write succeeded'
do
  grep -Fq "$expected" "$WORKFLOW" ||
    fail "caller token write probe workflow missing marker: $expected"
done

if grep -Fq "CLEANUP: \${{ inputs.cleanup || 'true' }}" "$WORKFLOW"; then
  fail "caller token write probe must preserve cleanup=false workflow_dispatch input"
fi

for forbidden in \
  'type: choice' \
  'options:' \
  'HUANLONG_PROBE_REPOS' \
  'matrix/caller-target-repos.txt' \
  'super-founder' \
  'hl-platform' \
  'hl-framework' \
  'hl-factory' \
  'hl-dispatch' \
  'hl-contracts' \
  'hl-console-native' \
  'team-memory' \
  '/pulls' \
  'sentinel-caller-sync'
do
  if grep -Fq "$forbidden" "$WORKFLOW"; then
    fail "caller token write probe workflow must not include forbidden marker: $forbidden"
  fi
done

echo "caller token write probe workflow test passed"
