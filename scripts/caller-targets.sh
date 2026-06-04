#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 from-file <REPO-MAP.md> | from-stdin" >&2
}

parse_repo_map() {
  local file="$1"

  awk -F'|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }

    /^### 1\.1 / {
      in_active = 1
      next
    }

    in_active && /^### / {
      exit
    }

    in_active && /^\| \*\*/ {
      repo = trim($2)
      governance = tolower(trim($8))
      gsub(/\*\*/, "", repo)

      if (repo == "" || seen[repo]++) next
      if (repo == "sentinel-shared") next
      if (governance ~ /deterministic-only/) next
      if (governance ~ /skip_llm:[[:space:]]*true/) next

      print repo
    }
  ' "$file"
}

case "${1:-}" in
  from-file)
    [ "${2:-}" ] || {
      usage
      exit 2
    }
    [ -f "$2" ] || {
      echo "REPO-MAP file not found: $2" >&2
      exit 1
    }
    parse_repo_map "$2"
    ;;
  from-stdin)
    parse_repo_map /dev/stdin
    ;;
  *)
    usage
    exit 2
    ;;
esac
