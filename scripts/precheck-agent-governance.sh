#!/usr/bin/env bash
set -euo pipefail

# D-10: Agent governance projection drift
# Checks Codex/Claude instruction entrypoints for stale owner/runtime projections
# and oversized AGENTS.md files that duplicate long-form project governance.

RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
AGENTS_MAX_BYTES="${AGENTS_MAX_BYTES:-32768}"

mkdir -p "$RESULTS_DIR"

echo "D-10: Agent governance projection drift"

PASSED=true
ISSUES=()
SCANNED=0

add_issue() {
  local issue="$1"
  ISSUES+=("$issue")
  PASSED=false
  echo "✗ $issue"
}

instruction_files() {
  find . \
    \( -path './.git' -o -path './.git/*' \
       -o -path './.build' -o -path './.build/*' \
       -o -path './.claude/worktrees' -o -path './.claude/worktrees/*' \
       -o -path './.sentinel/results' -o -path './.sentinel/results/*' \
       -o -path './.sentinel-shared' -o -path './.sentinel-shared/*' \) -prune \
    -o \( -name 'AGENTS.md' -o -name 'CLAUDE.md' \) -type f -print \
    | sed 's#^\./##' \
    | sort
}

if [ -f "CLAUDE.md" ] && [ ! -f "AGENTS.md" ]; then
  add_issue "CLAUDE.md exists but root AGENTS.md is missing"
fi

while IFS= read -r file; do
  [ -z "$file" ] && continue
  [ ! -f "$file" ] && continue
  SCANNED=$((SCANNED + 1))

  if [ "$(basename "$file")" = "AGENTS.md" ]; then
    size_bytes=$(wc -c < "$file" | tr -d ' ')
    if [ "$size_bytes" -gt "$AGENTS_MAX_BYTES" ]; then
      add_issue "$file exceeds ${AGENTS_MAX_BYTES} bytes"
    fi

    if [ -f "CLAUDE.md" ] && grep -Eq '^(##|###) (工作流硬约束|分阶段范围|光合设计系统约束|MAIA 节点层级铁律)' "$file"; then
      add_issue "$file duplicates long-form governance sections already owned by CLAUDE.md"
    fi
  fi

  if grep -nE 'Write-Owner:[^\n]*(NODE-M[[:space:]]*\+[[:space:]]*)?NODE-A|Write-Owner:[^\n]*NODE-A' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale NODE-A Write-Owner projection"
  fi

  if grep -nE '(6[[:space:]]*Git|6[[:space:]]*仓库|六[[:space:]]*(个)?仓库)' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale Huanlong fixed repository-count projection"
  fi

  if grep -nE '(^|[^[:alnum:]_])(01_Repos/)?_platform/sentinel-shared([^[:alnum:]_]|$)' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale sentinel-shared path projection"
  fi

  if grep -nE '(^|[^[:alnum:]_])(01_Repos/)?_governance/ltc-endpoint([^[:alnum:]_]|$)' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale ltc-endpoint path projection"
  fi

  if grep -nF '当前阶段快照' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale root phase snapshot projection"
  fi

  if grep -nE 'NODE-M[^\n]*(默认只读|read-only)[^\n]*(huanlong|hl-contracts|hl-platform|hl-framework|hl-factory|hl-console-native|hl-dispatch|team-memory)' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale NODE-M narrow read-only projection"
  fi

  if grep -nF 'GHThemeManager.current' "$file" >/dev/null 2>&1; then
    add_issue "$file contains stale GHThemeManager.current projection"
  fi
done < <(instruction_files)

RESULT_FILE="$RESULTS_DIR/d10-agent-governance.json"
jq -n \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson passed "$([[ "$PASSED" == true ]] && echo true || echo false)" \
  --argjson files_scanned "$SCANNED" \
  --argjson issues "$(if [ ${#ISSUES[@]} -gt 0 ]; then printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .; else echo '[]'; fi)" \
  '{
    check_id: "D-10",
    check_name: "Agent Governance",
    passed: $passed,
    files_scanned: $files_scanned,
    issues: $issues,
    timestamp: $timestamp
  }' > "$RESULT_FILE"

echo "Result written to $RESULT_FILE"

if [ "$PASSED" = false ]; then
  echo "::warning::D-10 Agent governance check failed"
  exit 1
fi

echo "D-10 PASS"
exit 0
