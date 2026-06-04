#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/caller-targets.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$SCRIPT" ] || fail "caller target resolver script must exist and be executable"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_MAP="$TMP_DIR/REPO-MAP.md"
cat > "$REPO_MAP" <<'MAP'
# REPO-MAP sample

### 1.1 活跃仓库（huanlongAI 组织）

| 仓库 | 域 | 本地路径 | 角色 | 可见性 | Write-Owner | 治理约束 |
|------|----|---------|------|--------|-------------|---------|
| **tzhOS** | _governance | `01_Repos/_governance/tzhOS` | 治理 SSOT | private | NODE-M | 自身即最高治理层 |
| **ltc-endpoint** | _governance | `01_Repos/_governance/ltc-endpoint` | LTC | private | NODE-M | R-0092 |
| **sentinel-shared** | _infra | `01_Repos/_infra/sentinel-shared` | Hub | public | NODE-M | tzhOS Sentinel |
| **tech-cofounder-bot** | _infra | `01_Repos/_infra/tech-cofounder-bot` | Runtime | private | NODE-M | MAIA |
| **tzh-context-atlas** | _infra | `01_Repos/_infra/tzh-context-atlas` | Context Atlas | private | NODE-M | tzhOS |
| **hl-scene-design-system** | huanlong | `01_Repos/huanlong/hl-scene-design-system` | Design system | private | NODE-E | hl-contracts |
| **hl-scene-app** | huanlong | `01_Repos/huanlong/hl-scene-app` | Scene app | private | NODE-E | SAAC-HL-001 |
| **hl-app-certificates** | huanlong | `01_Repos/huanlong/hl-app-certificates` | Signing | private | NODE-E | Consistency Sentinel deterministic-only（`skip_llm: true`） |
| **hl-portal** | huanlong | `01_Repos/huanlong/hl-portal` | Portal | private | NODE-E | portal governance |
| **TerraMind** | TerraMind | `01_Repos/TerraMind` | Thought base | private | NODE-M | TM-CHARTER-001 |

### 1.3 归档仓库（不再维护）

| 仓库 | 账户 | 归档原因 |
|------|------|---------|
| tzhos-server | tongzhenghui | R-0071 归档 |
MAP

targets="$("$SCRIPT" from-file "$REPO_MAP")"

for expected in \
  tzhOS \
  ltc-endpoint \
  tech-cofounder-bot \
  tzh-context-atlas \
  hl-scene-design-system \
  hl-scene-app \
  hl-portal \
  TerraMind
do
  grep -Fxq "$expected" <<<"$targets" ||
    fail "caller target resolver missing expected target: $expected"
done

for forbidden in \
  sentinel-shared \
  hl-app-certificates \
  tzhos-server
do
  if grep -Fxq "$forbidden" <<<"$targets"; then
    fail "caller target resolver must exclude: $forbidden"
  fi
done

if [ "$(printf '%s\n' "$targets" | sort | uniq -d | wc -l | tr -d ' ')" != "0" ]; then
  fail "caller target resolver must not emit duplicate targets"
fi

printf '%s\n' "$targets" | grep -Eq '^[A-Za-z0-9._-]+$' ||
  fail "caller target resolver must emit plain repo names"

echo "caller target resolver tests passed"
