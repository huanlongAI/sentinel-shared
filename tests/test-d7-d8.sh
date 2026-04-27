#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D7_SCRIPT="$ROOT_DIR/.sentinel/checks/d7-reverse-ssot.sh"
D8_SCRIPT="$ROOT_DIR/.sentinel/checks/d8-cross-repo-ssot.sh"

PASS_COUNT=0

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle"
    echo "Actual output:"
    echo "$haystack"
    exit 1
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "ok - $1"
}

make_guanghe_docs() {
  local dir="$1"
  local readme_ver="$2"
  local context_ver="$3"
  mkdir -p "$dir"
  cat > "$dir/CHANGELOG.md" <<EOF
# Changelog

## [Unreleased]

## [0.6.0-alpha] - 2026-03-26
EOF
  cat > "$dir/README.md" <<EOF
# Guanghe

## 版本

当前：**v${readme_ver}**
EOF
  cat > "$dir/CLAUDE-CONTEXT.md" <<EOF
# Context

- **最新 tag**: **${context_ver}**
EOF
}

make_upstream() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/CHANGELOG.md" <<EOF
# Changelog

## [Unreleased]

## [0.6.0-alpha] - 2026-03-26
EOF
}

make_downstream_semver() {
  local dir="$1"
  local version="$2"
  mkdir -p "$dir"
  cat > "$dir/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Downstream",
    dependencies: [
        .package(url: "https://github.com/tongzhenghui/guanghe.git", from: "${version}")
    ]
)
EOF
}

make_downstream_path() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Downstream",
    dependencies: [
        .package(path: "../../_infra/guanghe/packages/GHKit")
    ]
)
EOF
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# D-7 pass.
D7_PASS_DIR="$TMP_ROOT/d7-pass"
make_guanghe_docs "$D7_PASS_DIR" "0.6.0-alpha" "0.6.0-alpha"
(cd "$D7_PASS_DIR" && RESULTS_DIR="$TMP_ROOT/results-d7-pass" "$D7_SCRIPT") >/tmp/d7-pass.out
assert_contains "$(cat /tmp/d7-pass.out)" "PASS: D-7 reverse SSOT consistent at 0.6.0-alpha"
pass "D-7 accepts matching README and CLAUDE-CONTEXT versions"

# D-7 drift blocks.
D7_FAIL_DIR="$TMP_ROOT/d7-fail"
make_guanghe_docs "$D7_FAIL_DIR" "0.5.0-alpha" "0.6.0-alpha"
set +e
D7_FAIL_OUTPUT=$(cd "$D7_FAIL_DIR" && RESULTS_DIR="$TMP_ROOT/results-d7-fail" "$D7_SCRIPT" 2>&1)
D7_FAIL_CODE=$?
set -e
if [[ "$D7_FAIL_CODE" -eq 0 ]]; then
  echo "Expected D-7 drift to fail"
  exit 1
fi
assert_contains "$D7_FAIL_OUTPUT" "D-7 REVERSE SSOT DRIFT"
assert_contains "$D7_FAIL_OUTPUT" "README declared 0.5.0-alpha"
pass "D-7 blocks README reverse drift"

# D-8 current semver passes without warning.
UPSTREAM_DIR="$TMP_ROOT/upstream"
D8_CURRENT_DIR="$TMP_ROOT/d8-current"
make_upstream "$UPSTREAM_DIR"
make_downstream_semver "$D8_CURRENT_DIR" "0.6.0-alpha"
D8_CURRENT_OUTPUT=$(UPSTREAM_DIR="$UPSTREAM_DIR" DOWNSTREAM_DIR="$D8_CURRENT_DIR" RESULTS_DIR="$TMP_ROOT/results-d8-current" "$D8_SCRIPT")
assert_contains "$D8_CURRENT_OUTPUT" "PASS: D-8 downstream pin 0.6.0-alpha is within allowed drift"
pass "D-8 accepts current semver pin"

# D-8 old semver emits WARN but does not block.
D8_OLD_DIR="$TMP_ROOT/d8-old"
make_downstream_semver "$D8_OLD_DIR" "0.4.0-alpha"
D8_OLD_OUTPUT=$(UPSTREAM_DIR="$UPSTREAM_DIR" DOWNSTREAM_DIR="$D8_OLD_DIR" RESULTS_DIR="$TMP_ROOT/results-d8-old" "$D8_SCRIPT")
assert_contains "$D8_OLD_OUTPUT" "::warning::D-8 drift detected"
assert_contains "$D8_OLD_OUTPUT" "pinned=0.4.0-alpha"
pass "D-8 warns on stale 0.x semver pin without blocking"

# D-8 acknowledged current expiry suppresses drift warning.
D8_ACK_DIR="$TMP_ROOT/d8-ack"
make_downstream_semver "$D8_ACK_DIR" "0.4.0-alpha"
ACK_MSG="$TMP_ROOT/ack-message.txt"
cat > "$ACK_MSG" <<'EOF'
test commit

D-8-Acknowledged: sprint pin accepted
D-8-Expires: 2026-05-26
EOF
D8_ACK_OUTPUT=$(UPSTREAM_DIR="$UPSTREAM_DIR" DOWNSTREAM_DIR="$D8_ACK_DIR" D8_COMMIT_MESSAGE_FILE="$ACK_MSG" RESULTS_DIR="$TMP_ROOT/results-d8-ack" "$D8_SCRIPT")
assert_contains "$D8_ACK_OUTPUT" "D-8 drift acknowledged until 2026-05-26"
pass "D-8 honors unexpired acknowledgement trailer"

# D-8 expired acknowledgement warns.
D8_EXPIRED_DIR="$TMP_ROOT/d8-expired"
make_downstream_semver "$D8_EXPIRED_DIR" "0.4.0-alpha"
EXPIRED_MSG="$TMP_ROOT/expired-message.txt"
cat > "$EXPIRED_MSG" <<'EOF'
test commit

D-8-Acknowledged: old sprint pin
D-8-Expires: 2026-04-25
EOF
D8_EXPIRED_OUTPUT=$(UPSTREAM_DIR="$UPSTREAM_DIR" DOWNSTREAM_DIR="$D8_EXPIRED_DIR" D8_COMMIT_MESSAGE_FILE="$EXPIRED_MSG" RESULTS_DIR="$TMP_ROOT/results-d8-expired" "$D8_SCRIPT")
assert_contains "$D8_EXPIRED_OUTPUT" "::warning::D-8-Acknowledged trailer expired"
assert_contains "$D8_EXPIRED_OUTPUT" "::warning::D-8 drift detected"
pass "D-8 re-warns when acknowledgement trailer is expired"

# D-8 path dependencies are skipped for D-9.
D8_PATH_DIR="$TMP_ROOT/d8-path"
make_downstream_path "$D8_PATH_DIR"
D8_PATH_OUTPUT=$(UPSTREAM_DIR="$UPSTREAM_DIR" DOWNSTREAM_DIR="$D8_PATH_DIR" RESULTS_DIR="$TMP_ROOT/results-d8-path" "$D8_SCRIPT")
assert_contains "$D8_PATH_OUTPUT" "Downstream uses path-based dependency, D-8 skipped (handled by D-9)"
pass "D-8 skips path-based guanghe dependencies"

echo "All ${PASS_COUNT} D-7/D-8 tests passed"
