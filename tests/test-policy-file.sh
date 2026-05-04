#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D1_SCRIPT="$ROOT_DIR/scripts/precheck-changelog.sh"
D2_SCRIPT="$ROOT_DIR/scripts/precheck-terminology.sh"
D3_SCRIPT="$ROOT_DIR/scripts/precheck-cascade.sh"

PASS_COUNT=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle" >&2
    echo "Actual output:" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -q -- "$needle" "$file"; then
    echo "Expected $file to contain: $needle" >&2
    echo "Actual file:" >&2
    cat "$file" >&2
    exit 1
  fi
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "ok - $1"
}

init_repo() {
  local dir="$1"
  mkdir -p "$dir/.sentinel/results"
  git -C "$dir" init -q
  git -C "$dir" config user.email "sentinel-test@example.invalid"
  git -C "$dir" config user.name "Sentinel Test"
}

commit_all() {
  local dir="$1"
  local msg="$2"
  git -C "$dir" add .
  git -C "$dir" commit -q -m "$msg"
}

run_script_capture() {
  local dir="$1"
  local script="$2"
  set +e
  OUTPUT=$(cd "$dir" && bash "$script" 2>&1)
  CODE=$?
  set -e
}

write_base_config() {
  local dir="$1"
  mkdir -p "$dir/.sentinel"
  cat > "$dir/.sentinel/config.yaml"
}

test_no_policy_file_preserves_config_only_forbidden_terms() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - CONFIGONLYBLOCK
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "CONFIGONLYBLOCK appears here" > "$repo/sample.md"
  commit_all "$repo" "introduce config default term"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should fail on config-only forbidden_terms"
  fi
  assert_file_contains "$repo/.sentinel/results/d2-terminology.json" "CONFIGONLYBLOCK"
  pass "no policy_file preserves config-only forbidden_terms behavior"
}

test_policy_file_loads_forbidden_terms() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.yaml
YAML
  cat > "$repo/governance/sentinel-policy.yaml" <<'YAML'
forbidden_terms:
  - POLICYBLOCK
YAML
  echo "clean" > "$repo/policy.md"
  commit_all "$repo" "base"
  echo "POLICYBLOCK appears here" > "$repo/policy.md"
  commit_all "$repo" "introduce policy term"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should fail on forbidden_terms loaded from policy_file"
  fi
  assert_file_contains "$repo/.sentinel/results/d2-terminology.json" "POLICYBLOCK"
  pass "policy_file loads forbidden_terms"
}

test_policy_file_loads_terminology_exclude_patterns_with_config_term_fallback() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance" "$repo/docs"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  cat > "$repo/governance/sentinel-policy.yaml" <<'YAML'
terminology_exclude_patterns:
  - docs/excluded.md
YAML
  echo "clean" > "$repo/docs/excluded.md"
  commit_all "$repo" "base"
  echo "CONFIGTERM appears in excluded policy path" > "$repo/docs/excluded.md"
  commit_all "$repo" "change excluded path"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should pass when terminology_exclude_patterns come from policy_file"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  pass "policy_file loads terminology_exclude_patterns and falls back absent forbidden_terms to config"
}

test_policy_file_loads_governance_files() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.yaml
changelog_file: CHANGELOG.md
YAML
  cat > "$repo/governance/sentinel-policy.yaml" <<'YAML'
governance_files:
  - governance/policy.md
YAML
  echo "# Changelog" > "$repo/CHANGELOG.md"
  echo "base" > "$repo/governance/policy.md"
  commit_all "$repo" "base"
  echo "changed" > "$repo/governance/policy.md"
  commit_all "$repo" "change governance policy"

  run_script_capture "$repo" "$D1_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-1 should fail when governance_files loaded from policy_file changed without changelog"
  fi
  assert_file_contains "$repo/.sentinel/results/d1-changelog.json" "governance/policy.md was modified but CHANGELOG.md was not updated"
  pass "policy_file loads governance_files"
}

test_policy_file_loads_cascade_map() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.yaml
YAML
  cat > "$repo/governance/sentinel-policy.yaml" <<'YAML'
cascade_map:
  "governance/source.md": "governance/target.md"
YAML
  echo "base" > "$repo/governance/source.md"
  commit_all "$repo" "base"
  echo "changed" > "$repo/governance/source.md"
  commit_all "$repo" "change source"

  run_script_capture "$repo" "$D3_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-3 should fail when cascade_map loaded from policy_file points to missing target"
  fi
  assert_contains "$OUTPUT" "Target governance/target.md does not exist"
  pass "policy_file loads cascade_map"
}

test_missing_policy_file_fails_clearly() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
policy_file: governance/missing-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "clean change" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should fail when policy_file is missing"
  fi
  assert_contains "$OUTPUT" "policy_file not found"
  assert_contains "$OUTPUT" "governance/missing-policy.yaml"
  pass "missing policy_file fails clearly"
}

test_malformed_policy_file_fails_clearly() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance"
  write_base_config "$repo" <<'YAML'
policy_file: governance/malformed-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  cat > "$repo/governance/malformed-policy.yaml" <<'YAML'
forbidden_terms
  - POLICYTERM
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "clean change" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should fail when policy_file is malformed"
  fi
  assert_contains "$OUTPUT" "Malformed policy_file"
  assert_contains "$OUTPUT" "governance/malformed-policy.yaml"
  pass "malformed policy_file fails clearly"
}

test_path_level_terminology_excludes_match_nested_paths() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance/archive/old"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - PATHBLOCK
terminology_exclude_patterns:
  - governance/archive/**
YAML
  echo "clean" > "$repo/governance/archive/old/spec.md"
  commit_all "$repo" "base"
  echo "PATHBLOCK is intentionally archived" > "$repo/governance/archive/old/spec.md"
  commit_all "$repo" "change archived path"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should pass when path-level terminology_exclude_patterns match nested paths"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  pass "path-level terminology excludes match nested paths"
}

test_policy_file_loads_forbidden_terms
test_policy_file_loads_terminology_exclude_patterns_with_config_term_fallback
test_policy_file_loads_governance_files
test_policy_file_loads_cascade_map
test_missing_policy_file_fails_clearly
test_malformed_policy_file_fails_clearly
test_path_level_terminology_excludes_match_nested_paths
test_no_policy_file_preserves_config_only_forbidden_terms

echo "All ${PASS_COUNT} policy_file tests passed"
