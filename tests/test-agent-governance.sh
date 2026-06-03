#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/precheck-agent-governance.sh"

PASS_COUNT=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle"
    echo "Actual output:"
    echo "$haystack"
    exit 1
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "ok - $1"
}

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "sentinel@example.invalid"
  git -C "$dir" config user.name "Sentinel Test"
}

run_check() {
  local dir="$1"
  (cd "$dir" && RESULTS_DIR="$dir/.sentinel/results" "$SCRIPT" 2>&1)
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Missing Codex entrypoint is blocked when CLAUDE.md exists.
MISSING_AGENTS="$TMP_ROOT/missing-agents"
make_repo "$MISSING_AGENTS"
cat > "$MISSING_AGENTS/CLAUDE.md" <<'EOF'
# Repo CLAUDE
EOF
set +e
MISSING_OUTPUT=$(run_check "$MISSING_AGENTS")
MISSING_CODE=$?
set -e
if [ "$MISSING_CODE" -eq 0 ]; then
  fail "expected missing AGENTS.md to fail"
fi
assert_contains "$MISSING_OUTPUT" "CLAUDE.md exists but root AGENTS.md is missing"
pass "blocks CLAUDE.md without root AGENTS.md"

# Stale owner and theme projections are blocked.
STALE_REPO="$TMP_ROOT/stale"
make_repo "$STALE_REPO"
cat > "$STALE_REPO/AGENTS.md" <<'EOF'
# Repo AGENTS
EOF
cat > "$STALE_REPO/CLAUDE.md" <<'EOF'
# Repo CLAUDE

> **Write-Owner: NODE-M + NODE-A（并行）**

颜色通过 GHThemeManager.current.xxx 引用。
EOF
set +e
STALE_OUTPUT=$(run_check "$STALE_REPO")
STALE_CODE=$?
set -e
if [ "$STALE_CODE" -eq 0 ]; then
  fail "expected stale projections to fail"
fi
assert_contains "$STALE_OUTPUT" "stale NODE-A Write-Owner projection"
assert_contains "$STALE_OUTPUT" "stale GHThemeManager.current projection"
pass "blocks stale owner and theme projections"

# Long duplicate AGENTS.md is blocked.
LONG_REPO="$TMP_ROOT/long-agents"
make_repo "$LONG_REPO"
{
  echo "# Repo AGENTS"
  echo "## 工作流硬约束"
  head -c 33000 /dev/zero | tr '\0' 'a'
} > "$LONG_REPO/AGENTS.md"
cat > "$LONG_REPO/CLAUDE.md" <<'EOF'
# Repo CLAUDE
EOF
set +e
LONG_OUTPUT=$(run_check "$LONG_REPO")
LONG_CODE=$?
set -e
if [ "$LONG_CODE" -eq 0 ]; then
  fail "expected long AGENTS.md to fail"
fi
assert_contains "$LONG_OUTPUT" "AGENTS.md exceeds 32768 bytes"
assert_contains "$LONG_OUTPUT" "duplicates long-form governance sections"
pass "blocks long duplicate AGENTS.md"

# Thin AGENTS.md plus CLAUDE.md passes.
PASS_REPO="$TMP_ROOT/pass"
make_repo "$PASS_REPO"
cat > "$PASS_REPO/AGENTS.md" <<'EOF'
# Repo AGENTS

本文件是 Codex 入口。完整项目规则见 `CLAUDE.md`。
EOF
cat > "$PASS_REPO/CLAUDE.md" <<'EOF'
# Repo CLAUDE

> **Write-Owner: NODE-M**
EOF
PASS_OUTPUT=$(run_check "$PASS_REPO")
assert_contains "$PASS_OUTPUT" "D-10 PASS"
pass "accepts thin AGENTS.md projection"

echo "All ${PASS_COUNT} agent governance tests passed"
