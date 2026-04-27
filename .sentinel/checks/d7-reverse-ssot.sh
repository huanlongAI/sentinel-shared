#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
mkdir -p "$RESULTS_DIR"

result_file="$RESULTS_DIR/d7-reverse-ssot.json"

json_string_array() {
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

latest_changelog_version() {
  { grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md || true; } \
    | sed -E 's/^## \[([^]]+)\].*/\1/' \
    | { grep -vi '^unreleased$' || true; } \
    | head -1
}

extract_readme_version() {
  { grep -E '\*\*v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9-]+)?\*\*' README.md || true; } \
    | sed -E 's/.*\*\*v?([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9-]+)?)\*\*.*/\1/' \
    | head -1
}

extract_context_version() {
  { grep -E '\*\*最新 tag\*\*: \*\*?v?[0-9]+\.[0-9]+\.[0-9]+' CLAUDE-CONTEXT.md || true; } \
    | sed -E 's/.*\*\*最新 tag\*\*: \*\*?v?([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9-]+)?)\*\*?.*/\1/' \
    | head -1
}

echo "D-7: Reverse SSOT check"

issues=()
for required in CHANGELOG.md README.md CLAUDE-CONTEXT.md; do
  if [ ! -f "$required" ]; then
    issues+=("missing required file: $required")
  fi
done

if [ "${#issues[@]}" -eq 0 ]; then
  changelog_latest="$(latest_changelog_version)"
  readme_version="$(extract_readme_version)"
  context_version="$(extract_context_version)"

  [ -n "$changelog_latest" ] || issues+=("CHANGELOG latest version not found")
  [ -n "$readme_version" ] || issues+=("README declared version not found")
  [ -n "$context_version" ] || issues+=("CLAUDE-CONTEXT latest tag not found")

  if [ -n "${changelog_latest:-}" ] && [ -n "${readme_version:-}" ] && [ "$readme_version" != "$changelog_latest" ]; then
    issues+=("README declared $readme_version, CHANGELOG latest $changelog_latest")
  fi
  if [ -n "${changelog_latest:-}" ] && [ -n "${context_version:-}" ] && [ "$context_version" != "$changelog_latest" ]; then
    issues+=("CLAUDE-CONTEXT declared $context_version, CHANGELOG latest $changelog_latest")
  fi
fi

passed=true
if [ "${#issues[@]}" -gt 0 ]; then
  passed=false
fi

cat > "$result_file" <<EOF
{
  "check_id": "D-7",
  "check_name": "Reverse SSOT",
  "passed": $passed,
  "issues": $(json_string_array "${issues[@]}"),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

if [ "$passed" = false ]; then
  echo "D-7 REVERSE SSOT DRIFT"
  if [ -n "${changelog_latest:-}" ]; then
    echo "  CHANGELOG latest: $changelog_latest"
  fi
  if [ -n "${readme_version:-}" ]; then
    echo "  README declared: $readme_version"
  fi
  if [ -n "${context_version:-}" ]; then
    echo "  CLAUDE-CONTEXT declared: $context_version"
  fi
  printf '  - %s\n' "${issues[@]}"
  echo "Action: 同步 README 与 CLAUDE-CONTEXT 至 CHANGELOG 最新版本后重试"
  exit 1
fi

echo "PASS: D-7 reverse SSOT consistent at $changelog_latest"
exit 0
