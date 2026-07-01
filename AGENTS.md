# sentinel-shared — Codex Entry

本文件是 Codex 入口。完整项目规则见 `CLAUDE.md`，两者冲突时以 `CLAUDE.md` 和上游 tzhOS / AUM 真源为准。

## 仓库定位

`sentinel-shared` 是 Consistency Sentinel Hub，托管共享 reusable workflows、precheck scripts、LLM review 逻辑和 AGENTS 治理地图。

## Codex 执行约束

- 先执行 Repo Sync 预检；dirty、diverged、behind dirty 时先报告。
- 可复用 workflow 中不要声明 `permissions`，权限由 caller repo 声明。
- 脚本默认运行在 `set -euo pipefail` 下；`grep` 无匹配路径必须用 `{ grep ... || true; }` 或等价写法兜底。
- YAML 解析保持无 `yq` 依赖，沿用 `scripts/policy-loader.sh` 的 helper。
- Agent 入口与投影规则见 `docs/agents-governance-map.md`；新增或修改 `AGENTS.md` / `CLAUDE.md` 后必须跑 `bash tests/test-agent-governance.sh`。

## Boundary Engine v0.1

- Engine Gate decides when possible.
- Loss Budget decides small accepted losses.
- Hard Gate stops.
- Never ask TZH to continue.
- Run to terminal state.
- Do not present A/B/C for obvious next steps.

Terminal states:

- MERGED
- AUTO_MERGE_QUEUED
- PR_READY_WAITING_REVIEW
- PR_READY_NO_MERGE
- WAIT_CI
- WAIT_REVIEW
- WAIT_EXTERNAL
- ESCALATED_BATCH
- STOP_FAILED_GATE
- STOP_RISK_BOUNDARY
- STOP_BUDGET
