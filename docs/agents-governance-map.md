# HuanlongAI AGENTS Governance Map

> Status: ACTIVE  
> Last updated: 2026-06-03  
> Owner: NODE-M operational authority; AUM / tzhOS remain governance SSOT

本文件是 `huanlongAI` 工作区的 Agent 入口地图，不是新的规则真源。规则真源仍是各 repo 的 `CLAUDE.md`、上级 `AGENTS.md`、tzhOS / AUM registry、仓库 CI gate 与当前任务契约。

## Principles

- 每个正式 Git repo 根目录最多保留一个 Codex 入口 `AGENTS.md`。
- `AGENTS.md` 应是薄入口，避免复制 `CLAUDE.md` 的长篇治理正文。
- 只有子目录存在不同权限边界、接口 SSOT、安全规则或测试入口时，才允许新增 nested `AGENTS.md`。
- Desktop UI、`~/.codex/*`、`~/.claude/*`、memory、chat history 和本地 cache 都是 deploy target projection，不是治理 SSOT。
- 入口漂移由 Sentinel `D-10 Agent Governance` 检查兜底。

## Repo Map

| Repo | Codex entry | Claude entry | Rule owner | Nested AGENTS | Verification |
|------|-------------|--------------|------------|---------------|--------------|
| `super-founder` | `AGENTS.md` thin entry | `CLAUDE.md` long-form project rules | `CLAUDE.md` + tzhOS R-0122 / AUM | Disabled by default | `bash ../sentinel-shared/scripts/precheck-agent-governance.sh` from repo root |
| `sentinel-shared` | `AGENTS.md` thin entry | `CLAUDE.md` hub rules | `CLAUDE.md` + this map | Disabled by default | `bash tests/test-agent-governance.sh` |

## Drift Rules

Sentinel D-10 blocks:

- root `CLAUDE.md` without root `AGENTS.md`;
- stale `Write-Owner: NODE-A` / `NODE-M + NODE-A` projections;
- stale `GHThemeManager.current` theme guidance;
- long `AGENTS.md` files over 32 KiB;
- `AGENTS.md` duplicating long-form sections that should live in `CLAUDE.md`.
