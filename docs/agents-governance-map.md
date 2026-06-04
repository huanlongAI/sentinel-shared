# HuanlongAI AGENTS Governance Map

> Status: ACTIVE
> Last updated: 2026-06-04
> Owner: NODE-M operational authority; AUM / tzhOS remain governance SSOT

本文件是 `huanlongAI` 工作区的 Agent 入口治理地图，不是新的仓库清单真源，也不是新的规则真源。活跃仓库清单以 tzhOS `40-PPR/REPO-MAP.md@v1.4.12` 为 SSOT；规则真源仍是各 repo 的 `CLAUDE.md`、直接或目录继承的 `AGENTS.md`、tzhOS / AUM registry、仓库 CI gate 与当前任务契约。

## Principles

- 每个正式 Git repo 根目录最多保留一个 Codex 入口 `AGENTS.md`。
- `AGENTS.md` 应是薄入口，避免复制 `CLAUDE.md` 的长篇治理正文。
- 只有子目录存在不同权限边界、接口 SSOT、安全规则或测试入口时，才允许新增 nested `AGENTS.md`。
- 不在本文件维护 26 仓逐仓清单；逐仓活跃状态和本地路径由 tzhOS `REPO-MAP.md` 维护，入口覆盖由 tzhOS `40-PPR/check-deps.sh` 动态验证。
- Desktop UI、`~/.codex/*`、`~/.claude/*`、memory、chat history 和本地 cache 都是 deploy target projection，不是治理 SSOT。
- 入口漂移由 Sentinel `D-10 Agent Governance` 检查兜底。

## Coverage Model

| Layer | Owner | Purpose | Verification |
|-------|-------|---------|--------------|
| Active repo inventory | tzhOS `40-PPR/REPO-MAP.md@v1.4.12` | 26 active repos, paths, visibility, Write-Owner, repo-level constraints | `bash 40-PPR/check-deps.sh` in tzhOS |
| Entry coverage | tzhOS `40-PPR/check-deps.sh` | Dynamic check that every active repo has a direct or inherited `AGENTS.md` / `CLAUDE.md` entry | tzhOS governance-check / local `check-deps.sh` |
| Projection drift | sentinel-shared D-10 | Repo-local scan for stale owner/runtime projection and oversized duplicated `AGENTS.md` files | `bash scripts/precheck-agent-governance.sh` from target repo root |
| Map invariants | sentinel-shared tests | Prevent this map from becoming a second stale repo inventory | `bash tests/test-agent-governance.sh` |

## Exception Map

This table records only exceptions and important entry topology. It is not a full repo inventory.

| Scope | Codex entry | Claude entry | Rule owner | Notes |
|-------|-------------|--------------|------------|-------|
| `super-founder` | root `AGENTS.md` thin entry | root `CLAUDE.md` long-form project rules | `CLAUDE.md` + tzhOS R-0122 / AUM | Root `AGENTS.md` must stay thin; D-10 blocks stale NODE-A and long duplicated governance sections. |
| `sentinel-shared` | root `AGENTS.md` thin entry | root `CLAUDE.md` hub rules | `CLAUDE.md` + this map | Changes to Agent governance scripts/docs require `bash tests/test-agent-governance.sh`. |
| `hl-app-certificates` | inherited `huanlong/AGENTS.md` | none at repo root | tzhOS `REPO-MAP.md@v1.4.12` + repo README/security boundary | Signing asset repository; Sentinel caller is deterministic-only / `skip_llm: true`; `.p8` material must stay in Secret Store. |

## Drift Rules

Sentinel D-10 blocks:

- root `CLAUDE.md` without root `AGENTS.md`;
- stale `Write-Owner: NODE-A` / `NODE-M + NODE-A` projections;
- stale narrow `NODE-M` read-only projections for Huanlong active repos;
- stale `GHThemeManager.current` theme guidance;
- long `AGENTS.md` files over 32 KiB;
- `AGENTS.md` duplicating long-form sections that should live in `CLAUDE.md`.
