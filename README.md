# sentinel-shared

Consistency Sentinel 共享基础设施 — Reusable Workflows + Scripts + Matrix。

## LLM Provider Router

`scripts/llm-review.sh` 支持以下 provider：

- `auto`：默认值。优先使用 HeiyuCode token；否则回退 Anthropic official；都不存在则跳过 LLM 层。
- `anthropic`：使用 Anthropic official Messages API。
- `heiyucode` / `heiyucode_claude_code`：使用 HeiyuCode Claude Code client transport。

Reusable workflow inputs：

- `llm_provider`：`auto` / `anthropic` / `heiyucode`
- `heiyucode_base_url`：默认 `https://www.heiyucode.com`
- `heiyucode_model`：可选模型覆盖；为空时使用 caller repo `.sentinel/config.yaml` 的 `llm.model`

Reusable workflow secrets：

- `ANTHROPIC_API_KEY`
- `HEIYUCODE_AUTH_TOKEN`
- `HEIYUCODE_API_KEY`

HeiyuCode 路由会优先读取 `HEIYUCODE_AUTH_TOKEN`，再读取 `HEIYUCODE_API_KEY`。
