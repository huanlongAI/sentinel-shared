# sentinel-shared — Consistency Sentinel Hub

> **Write-Owner: NODE-M** — MULTI-NODE-COWORK-SPEC v0.3 §3.2

## 仓库定位

sentinel-shared 是 Consistency Sentinel 系统的 **Hub 中枢**，托管所有仓库共用的可复用 workflow、预检脚本和 LLM 审查逻辑。

## 关键约束

1. **必须保持 PUBLIC**：GITHUB_TOKEN 作用域限制，私有 repo 的 caller workflow 无法引用私有 repo 的可复用 workflow。sentinel-shared 不含秘钥，只含 CI 脚本。
2. **可复用 workflow 中禁止声明 permissions**：permissions 必须在各 spoke repo 的 caller workflow 中声明。在此处声明会导致 GitHub Actions startup_failure（0s/0 jobs，无错误信息）。
3. **脚本运行在 `set -euo pipefail` 下**：所有 grep 管道必须用 `{ grep ... || true; }` 包装，避免无匹配时管道失败。
4. **YAML 解析不依赖 yq**：通过自定义 bash 函数（yaml_get / yaml_get_nested / yaml_get_nested_array）实现，以支持最小化 CI 环境。

## 文件结构

```
.github/workflows/
  consistency-sentinel.yml   # 可复用 workflow（callee），被 16 个 repo 调用
scripts/
  precheck-changelog.sh      # D-1: CHANGELOG 留痕
  precheck-terminology.sh    # D-2: 术语 SSOT 扫描
  precheck-cascade.sh        # D-3: 级联引用完整性
  precheck-directory.sh      # D-4: 目录规范
  precheck-capability-source.sh  # D-5: 能力来源标注
  precheck-brand-token.sh    # D-6: Brand Token 硬编码检测
  llm-review.sh              # LLM 一致性审查（Claude API）
prompts/
  system-prompt.md           # LLM 审查层 system prompt
```

## 规格引用

- CONSEN-SPEC-001 v1.1（tzhOS）
- REPO-MAP-001 v1.0（tzhOS）
