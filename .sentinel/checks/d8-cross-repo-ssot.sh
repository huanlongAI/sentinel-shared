#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_DIR="${UPSTREAM_DIR:-upstream}"
DOWNSTREAM_DIR="${DOWNSTREAM_DIR:-downstream}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
MAX_ALLOWED_DRIFT_0X="${MAX_ALLOWED_DRIFT_0X:-0}"
MAX_ALLOWED_DRIFT_1X_PLUS="${MAX_ALLOWED_DRIFT_1X_PLUS:-1}"
UPSTREAM_NAME="${UPSTREAM_NAME:-guanghe}"
DOWNSTREAM_NAME="${DOWNSTREAM_NAME:-downstream}"

mkdir -p "$RESULTS_DIR"
result_file="$RESULTS_DIR/d8-cross-repo-ssot.json"

json_string_array() {
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

latest_changelog_version() {
  { grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+' "$UPSTREAM_DIR/CHANGELOG.md" || true; } \
    | sed -E 's/^## \[([^]]+)\].*/\1/' \
    | { grep -vi '^unreleased$' || true; } \
    | head -1
}

read_commit_message() {
  if [ -n "${D8_COMMIT_MESSAGE_FILE:-}" ] && [ -f "$D8_COMMIT_MESSAGE_FILE" ]; then
    cat "$D8_COMMIT_MESSAGE_FILE"
    return
  fi
  if git -C "$DOWNSTREAM_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$DOWNSTREAM_DIR" log -1 --pretty=%B
    return
  fi
  echo ""
}

date_plus_30_days() {
  local base="$1"
  if date -u -d "$base +30 days" +%Y-%m-%d >/dev/null 2>&1; then
    date -u -d "$base +30 days" +%Y-%m-%d
  elif date -u -j -v+30d -f "%Y-%m-%d" "$base" +%Y-%m-%d >/dev/null 2>&1; then
    date -u -j -v+30d -f "%Y-%m-%d" "$base" +%Y-%m-%d
  else
    echo ""
  fi
}

drift_segments() {
  local pinned="$1"
  local latest="$2"
  local p_major p_minor l_major l_minor
  p_major="$(echo "$pinned" | cut -d. -f1)"
  p_minor="$(echo "$pinned" | cut -d. -f2)"
  l_major="$(echo "$latest" | cut -d. -f1)"
  l_minor="$(echo "$latest" | cut -d. -f2)"
  if [ "$p_major" != "$l_major" ]; then
    echo $((100 + (l_minor - p_minor)))
    return
  fi
  if [ "$p_minor" != "$l_minor" ]; then
    echo $((l_minor - p_minor))
    return
  fi
  echo 0
}

write_result() {
  local passed="$1"
  shift
  local status="$1"
  shift
  local warnings=("$@")
  cat > "$result_file" <<EOF
{
  "check_id": "D-8",
  "check_name": "Cross-Repo SSOT",
  "passed": $passed,
  "status": "$status",
  "warnings": $(json_string_array "${warnings[@]}"),
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

echo "D-8: Cross-repo SSOT check"

if [ ! -f "$UPSTREAM_DIR/CHANGELOG.md" ]; then
  echo "::error::missing upstream CHANGELOG.md at $UPSTREAM_DIR"
  write_result false "config_error" "missing upstream CHANGELOG.md"
  exit 1
fi
if [ ! -f "$DOWNSTREAM_DIR/Package.swift" ]; then
  echo "::warning::missing downstream Package.swift at $DOWNSTREAM_DIR"
  write_result true "skipped" "missing downstream Package.swift"
  exit 0
fi

upstream_ver="$(latest_changelog_version)"
if [ -z "$upstream_ver" ]; then
  echo "::error::upstream latest version not found"
  write_result false "config_error" "upstream latest version not found"
  exit 1
fi

if grep -Eq '\.package\(path:.*guanghe' "$DOWNSTREAM_DIR/Package.swift"; then
  echo "::notice::Downstream uses path-based dependency, D-8 skipped (handled by D-9)"
  write_result true "skipped_path_dependency"
  exit 0
fi

pinned_ver="$({ grep -E '\.package\(url: ".*guanghe\.git".*(from|exact): "[^"]+"' "$DOWNSTREAM_DIR/Package.swift" || true; } \
  | sed -E 's/.*(from|exact): "([^"]+)".*/\2/' \
  | head -1)"

if [ -z "$pinned_ver" ]; then
  echo "::notice::No semver guanghe dependency found; D-8 skipped"
  write_result true "skipped_no_semver_dependency"
  exit 0
fi

upstream_major="$(echo "$upstream_ver" | cut -d. -f1)"
if [ "$upstream_major" = "0" ]; then
  max_drift="$MAX_ALLOWED_DRIFT_0X"
else
  max_drift="$MAX_ALLOWED_DRIFT_1X_PLUS"
fi

drift="$(drift_segments "$pinned_ver" "$upstream_ver")"
warnings=()

if [ "$drift" -gt "$max_drift" ]; then
  commit_message="$(read_commit_message)"
  ack_reason="$(printf '%s\n' "$commit_message" | awk -F: '$1 == "D-8-Acknowledged" {sub(/^[[:space:]]*/, "", $2); print $2; exit}')"
  ack_expires="$(printf '%s\n' "$commit_message" | awk -F: '$1 == "D-8-Expires" {sub(/^[[:space:]]*/, "", $2); print $2; exit}')"
  if [ -n "$ack_reason" ] && [ -z "$ack_expires" ]; then
    ack_expires="$(date_plus_30_days "$(date -u +%Y-%m-%d)")"
  fi

  today="$(date -u +%Y-%m-%d)"
  if [ -n "$ack_reason" ] && [ -n "$ack_expires" ] && [[ "$today" < "$ack_expires" || "$today" == "$ack_expires" ]]; then
    echo "::notice::D-8 drift acknowledged until $ack_expires"
    echo "D-8 drift acknowledged until $ack_expires"
    write_result true "acknowledged"
    exit 0
  fi

  if [ -n "$ack_reason" ] && [ -n "$ack_expires" ]; then
    expired_msg="D-8-Acknowledged trailer expired ($ack_expires); please re-acknowledge or upgrade"
    echo "::warning::$expired_msg"
    warnings+=("$expired_msg")
  fi

  drift_msg="D-8 drift detected: upstream=$upstream_ver, pinned=$pinned_ver, drift=$drift segments (over MAX=$max_drift for ${upstream_major}.x)"
  echo "::warning::$drift_msg"
  warnings+=("$drift_msg")
  write_result true "warn" "${warnings[@]}"
  exit 0
fi

echo "PASS: D-8 downstream pin $pinned_ver is within allowed drift from upstream $upstream_ver"
write_result true "pass"
exit 0
