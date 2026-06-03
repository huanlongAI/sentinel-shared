# sentinel-shared

Consistency Sentinel 共享基础设施 — Reusable Workflows + Scripts + Matrix。

## Deterministic Prechecks

- `D-10 Agent Governance`：扫描 `AGENTS.md` / `CLAUDE.md` 入口投影，阻断旧 `NODE-A` Write-Owner、旧 `GHThemeManager.current` 口径、缺失 Codex 根入口、超出 32 KiB 的长 `AGENTS.md` 以及 `AGENTS.md` 重复长篇治理正文。

## LLM Provider Router

`scripts/llm-review.sh` 支持以下 provider：

- `auto`：默认值。优先使用 HeiyuCode token；否则回退 Anthropic official；都不存在则跳过 LLM 层。
- `anthropic`：使用 Anthropic official Messages API。
- `heiyucode` / `heiyucode_claude_code`：使用 HeiyuCode Anthropic-compatible Messages API transport。

Reusable workflow inputs：

- `llm_provider`：`auto` / `anthropic` / `heiyucode`
- `heiyucode_base_url`：默认 `https://www.heiyucode.com`
- `heiyucode_model`：可选模型覆盖；为空时使用 caller repo `.sentinel/config.yaml` 的 `llm.model`

Reusable workflow secrets：

- `ANTHROPIC_API_KEY`
- `HEIYUCODE_AUTH_TOKEN`
- `HEIYUCODE_API_KEY`

HeiyuCode 路由会优先读取 `HEIYUCODE_AUTH_TOKEN`，再读取 `HEIYUCODE_API_KEY`。默认先按 `Authorization: Bearer` 调用，若返回 401/403，再用 `x-api-key` 重试一次；日志只记录 header 类型，不输出 secret 值。
