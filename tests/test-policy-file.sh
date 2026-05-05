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
  assert_contains "$OUTPUT" "Read forbidden terms from config"
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
  assert_contains "$OUTPUT" "Read forbidden terms from policy_file: governance/sentinel-policy.yaml"
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

test_policy_file_parent_escape_is_rejected() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
policy_file: ../outside-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  cat > "$tmp/outside-policy.yaml" <<'YAML'
forbidden_terms:
  - OUTSIDEBLOCK
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "OUTSIDEBLOCK appears here" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should reject policy_file that escapes repository root via .."
  fi
  assert_contains "$OUTPUT" "policy_file must stay within repository root"
  assert_contains "$OUTPUT" "../outside-policy.yaml"
  pass "policy_file parent-directory escape is rejected"
}

test_policy_file_symlink_escape_is_rejected() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/governance"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  cat > "$tmp/outside-policy.yaml" <<'YAML'
forbidden_terms:
  - OUTSIDEBLOCK
YAML
  ln -s "$tmp/outside-policy.yaml" "$repo/governance/sentinel-policy.yaml"
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "OUTSIDEBLOCK appears here" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should reject policy_file symlink that escapes repository root"
  fi
  assert_contains "$OUTPUT" "policy_file must stay within repository root"
  assert_contains "$OUTPUT" "governance/sentinel-policy.yaml"
  pass "policy_file symlink escape is rejected"
}

test_absolute_policy_file_path_is_rejected() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  cat > "$tmp/outside-policy.yaml" <<'YAML'
forbidden_terms:
  - OUTSIDEBLOCK
YAML
  write_base_config "$repo" <<YAML
policy_file: $tmp/outside-policy.yaml
forbidden_terms:
  - CONFIGTERM
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "clean change" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should reject absolute policy_file path"
  fi
  assert_contains "$OUTPUT" "policy_file must be repository-relative, not absolute"
  assert_contains "$OUTPUT" "$tmp/outside-policy.yaml"
  pass "absolute policy_file path is rejected"
}

test_non_yaml_policy_file_path_is_rejected() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
policy_file: governance/sentinel-policy.txt
forbidden_terms:
  - CONFIGTERM
YAML
  echo "clean" > "$repo/sample.md"
  commit_all "$repo" "base"
  echo "clean change" > "$repo/sample.md"
  commit_all "$repo" "change"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should reject non-YAML policy_file path"
  fi
  assert_contains "$OUTPUT" "policy_file must be a YAML file (.yaml or .yml)"
  assert_contains "$OUTPUT" "governance/sentinel-policy.txt"
  pass "non-YAML policy_file path is rejected"
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

test_d3_cascade_block_list_full_tzhOS_shape() {
  local tmp repo result line_count
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
cascade_map:
  "MIRA-001.md":
    - "SAAC-001.md"
    - "BOOTSTRAP.md"
    - "CONTEXT.md"
    - "CONSEN-SPEC-001.md"
  "SAAC-001.md":
    - "CONTEXT.md"
    - "BOOTSTRAP.md"
  "00-CHARTER/mission-telos.md":
    - "CONTEXT.md"
    - "BOOTSTRAP.md"
  "00-CHARTER/governance.md":
    - "CONTEXT.md"
    - "BOOTSTRAP.md"
    - "RULINGS.md"
    - "CHANGELOG.md"
  "00-CHARTER/collaboration-standard.md":
    - "CONTEXT.md"
    - "BOOTSTRAP.md"
  "00-CHARTER/interface-standard.md":
    - "CONTEXT.md"
    - "BOOTSTRAP.md"
    - "20-DIGITAL-WORKBENCH/templates/interface-declaration.template.md"
  "00-CHARTER/playbooks/decision-gate.md":
    - "CONTEXT.md"
    - "RULINGS.md"
  "00-CHARTER/playbooks/monthly-audit-review.md":
    - "CONTEXT.md"
  "40-VAH/VAH-001.md":
    - "INDEX.md"
    - "MASTER-OVERVIEW.md"
    - "CONTEXT.md"
    - "ai/VAH-METHODOLOGY.md"
    - "40-VAH/GATE-EVIDENCE-ENVELOPE-v0.md"
  "ai/VAH-METHODOLOGY.md":
    - "INDEX.md"
    - "MASTER-OVERVIEW.md"
    - "CONTEXT.md"
    - "ai/PLAYBOOK.md"
    - "40-VAH/VAH-001.md"
    - "40-VAH/GATE-EVIDENCE-ENVELOPE-v0.md"
  "40-VAH/GATE-EVIDENCE-ENVELOPE-v0.md":
    - "INDEX.md"
    - "RULINGS.md"
    - "40-VAH/VAH-001.md"
    - "ai/VAH-METHODOLOGY.md"
YAML

  source "$ROOT_DIR/scripts/policy-loader.sh"
  result=$(sentinel_yaml_get_map "$repo/.sentinel/config.yaml" "cascade_map")
  line_count=$(printf '%s\n' "$result" | awk 'NF { count++ } END { print count + 0 }')
  [ "$line_count" -eq 35 ] || fail "expected 35 cascade edges, got $line_count"
  assert_contains "$result" "MIRA-001.md=SAAC-001.md"
  assert_contains "$result" "00-CHARTER/interface-standard.md=20-DIGITAL-WORKBENCH/templates/interface-declaration.template.md"
  assert_contains "$result" "40-VAH/GATE-EVIDENCE-ENVELOPE-v0.md=ai/VAH-METHODOLOGY.md"
  if printf '%s\n' "$result" | grep -Eq '=$'; then
    fail "cascade block-list output must not contain empty targets"
  fi
  if printf '%s\n' "$result" | grep -Ev '^[^=]+=[^=]+$' | grep -q .; then
    fail "cascade block-list output contains malformed edge"
  fi
  rm -rf "$tmp"
  pass "cascade_map block-style list expands tzhOS 35 edges"
}

test_d3_cascade_flow_scalar_hl_contracts_shape() {
  local tmp repo result line_count
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
cascade_map:
  "TRACEABILITY.yaml": "CHANGELOG.md"
  "governance/RULINGS.md": "CHANGELOG.md"
YAML

  source "$ROOT_DIR/scripts/policy-loader.sh"
  result=$(sentinel_yaml_get_map "$repo/.sentinel/config.yaml" "cascade_map")
  line_count=$(printf '%s\n' "$result" | awk 'NF { count++ } END { print count + 0 }')
  [ "$line_count" -eq 2 ] || fail "expected 2 flow scalar edges, got $line_count"
  assert_contains "$result" "TRACEABILITY.yaml=CHANGELOG.md"
  assert_contains "$result" "governance/RULINGS.md=CHANGELOG.md"
  rm -rf "$tmp"
  pass "cascade_map flow-style scalar remains compatible"
}

test_d3_cascade_inline_empty_map() {
  local tmp repo result line_count
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
cascade_map: {}
YAML

  source "$ROOT_DIR/scripts/policy-loader.sh"
  result=$(sentinel_yaml_get_map "$repo/.sentinel/config.yaml" "cascade_map")
  line_count=$(printf '%s\n' "$result" | awk 'NF { count++ } END { print count + 0 }')
  [ "$line_count" -eq 0 ] || fail "expected empty inline map to produce 0 edges, got $line_count"
  rm -rf "$tmp"
  pass "cascade_map inline empty map remains empty"
}

test_d3_cascade_missing_section() {
  local tmp repo result line_count
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - MISSINGSECTIONTERM
YAML

  source "$ROOT_DIR/scripts/policy-loader.sh"
  result=$(sentinel_yaml_get_map "$repo/.sentinel/config.yaml" "cascade_map")
  line_count=$(printf '%s\n' "$result" | awk 'NF { count++ } END { print count + 0 }')
  [ "$line_count" -eq 0 ] || fail "expected missing cascade_map section to produce 0 edges, got $line_count"
  rm -rf "$tmp"
  pass "missing cascade_map section remains empty"
}

test_d3_cascade_inline_empty_list_regression() {
  local tmp repo result line_count
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  write_base_config "$repo" <<'YAML'
cascade_map:
  "FOO.md": []
YAML

  source "$ROOT_DIR/scripts/policy-loader.sh"
  result=$(sentinel_yaml_get_map "$repo/.sentinel/config.yaml" "cascade_map")
  line_count=$(printf '%s\n' "$result" | awk 'NF { count++ } END { print count + 0 }')
  [ "$line_count" -eq 0 ] || fail "expected inline empty list to produce 0 edges, got $line_count"
  rm -rf "$tmp"
  pass "cascade_map inline empty list does not emit false target"
}

test_d2_exclude_slash_zero_depth() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/40-VAH"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - PATHBLOCK
terminology_exclude_patterns:
  - 40-VAH/**/*.md
YAML
  echo "clean" > "$repo/40-VAH/foo.md"
  commit_all "$repo" "base"
  echo "PATHBLOCK intentionally excluded" > "$repo/40-VAH/foo.md"
  commit_all "$repo" "change zero-depth excluded file"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should pass when slash pattern excludes zero-depth path"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  rm -rf "$tmp"
  pass "terminology slash pattern excludes zero-depth path"
}

test_d2_exclude_slash_multi_depth() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/40-VAH/observations"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - PATHBLOCK
terminology_exclude_patterns:
  - 40-VAH/**/*.md
YAML
  echo "clean" > "$repo/40-VAH/observations/bar.md"
  commit_all "$repo" "base"
  echo "PATHBLOCK intentionally excluded" > "$repo/40-VAH/observations/bar.md"
  commit_all "$repo" "change multi-depth excluded file"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should pass when slash pattern excludes multi-depth path"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  rm -rf "$tmp"
  pass "terminology slash pattern excludes multi-depth path"
}

test_d2_exclude_basename_legacy_anywhere() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/docs"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - BASEBLOCK
terminology_exclude_patterns:
  - "*-rules.md"
YAML
  echo "clean" > "$repo/docs/lint-rules.md"
  commit_all "$repo" "base"
  echo "BASEBLOCK intentionally excluded" > "$repo/docs/lint-rules.md"
  commit_all "$repo" "change basename excluded file"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should preserve basename glob excludes in nested directories"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  rm -rf "$tmp"
  pass "terminology basename glob excludes nested filename"
}

test_d2_exclude_basename_anchor_anywhere() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/nested"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - BASEBLOCK
terminology_exclude_patterns:
  - AI_MEMORY.md
YAML
  echo "clean" > "$repo/nested/AI_MEMORY.md"
  commit_all "$repo" "base"
  echo "BASEBLOCK intentionally excluded" > "$repo/nested/AI_MEMORY.md"
  commit_all "$repo" "change basename anchored file"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should preserve exact basename excludes in nested directories"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  rm -rf "$tmp"
  pass "terminology exact basename excludes nested filename"
}

test_d2_exclude_no_match() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/40-PPR"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - PATHBLOCK
terminology_exclude_patterns:
  - 40-VAH/**/*.md
YAML
  echo "clean" > "$repo/40-PPR/PPR.md"
  commit_all "$repo" "base"
  echo "PATHBLOCK should not be excluded" > "$repo/40-PPR/PPR.md"
  commit_all "$repo" "change non-matching path"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -eq 0 ]; then
    fail "D-2 should fail when slash pattern does not match changed file"
  fi
  assert_file_contains "$repo/.sentinel/results/d2-terminology.json" "PATHBLOCK"
  rm -rf "$tmp"
  pass "terminology slash pattern does not exclude unrelated path"
}

test_d2_exclude_path_basename_conflict_either_wins() {
  local tmp repo
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  init_repo "$repo"
  mkdir -p "$repo/40-VAH"
  write_base_config "$repo" <<'YAML'
forbidden_terms:
  - PATHBLOCK
terminology_exclude_patterns:
  - 40-VAH/**/*.md
  - "*-rules.md"
YAML
  echo "clean" > "$repo/40-VAH/foo-rules.md"
  commit_all "$repo" "base"
  echo "PATHBLOCK intentionally excluded" > "$repo/40-VAH/foo-rules.md"
  commit_all "$repo" "change path and basename excluded file"

  run_script_capture "$repo" "$D2_SCRIPT"
  if [ "$CODE" -ne 0 ]; then
    echo "$OUTPUT" >&2
    fail "D-2 should exclude when either slash pattern or basename pattern matches"
  fi
  assert_contains "$OUTPUT" "Excluded 1 files by terminology_exclude_patterns"
  rm -rf "$tmp"
  pass "terminology excludes when path or basename pattern matches"
}

test_policy_file_loads_forbidden_terms
test_policy_file_loads_terminology_exclude_patterns_with_config_term_fallback
test_policy_file_loads_governance_files
test_policy_file_loads_cascade_map
test_missing_policy_file_fails_clearly
test_malformed_policy_file_fails_clearly
test_policy_file_parent_escape_is_rejected
test_policy_file_symlink_escape_is_rejected
test_absolute_policy_file_path_is_rejected
test_non_yaml_policy_file_path_is_rejected
test_path_level_terminology_excludes_match_nested_paths
test_no_policy_file_preserves_config_only_forbidden_terms
test_d3_cascade_block_list_full_tzhOS_shape
test_d3_cascade_flow_scalar_hl_contracts_shape
test_d3_cascade_inline_empty_map
test_d3_cascade_missing_section
test_d3_cascade_inline_empty_list_regression
test_d2_exclude_slash_zero_depth
test_d2_exclude_slash_multi_depth
test_d2_exclude_basename_legacy_anywhere
test_d2_exclude_basename_anchor_anywhere
test_d2_exclude_no_match
test_d2_exclude_path_basename_conflict_either_wins

echo "All ${PASS_COUNT} policy_file tests passed"
