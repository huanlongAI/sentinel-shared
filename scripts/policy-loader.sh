#!/usr/bin/env bash
# Shared Sentinel policy/config helpers.
#
# Contract:
# - .sentinel/config.yaml remains the runtime/tool config file.
# - Optional config key `policy_file` points to a repository-relative YAML file.
# - Governance policy keys are read from policy_file when that key is present
#   there; otherwise they fall back to .sentinel/config.yaml for compatibility.
# - No yq dependency: this intentionally supports the small YAML subset already
#   used by Sentinel configs (top-level scalars, arrays, and simple maps).

sentinel_trim_yaml_value() {
  sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[[:space:]]+|[[:space:]]+$//g' \
    | tr -d '"' \
    | tr -d "'"
}

sentinel_yaml_get() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 | sentinel_trim_yaml_value || true)
  echo "${val:-$default}"
}

sentinel_yaml_has_top_key() {
  local file="$1" key="$2"
  grep -Eq "^${key}:[[:space:]]*($|#|.*)" "$file" 2>/dev/null
}

sentinel_yaml_get_array() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*($|#)" { in_array=1; next }
    in_array && $0 ~ "^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*" { exit }
    in_array && $0 ~ "^[[:space:]]*-" {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/["'\''"]/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$file" 2>/dev/null || true
}

sentinel_yaml_get_map() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*($|#)" { in_map=1; next }
    in_map && $0 ~ "^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*" { exit }
    in_map && $0 ~ "^[[:space:]]+[^#[:space:]][^:]*:[[:space:]]*" {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/["'\''"]/, "", line)
      sub(/[[:space:]]*:[[:space:]]*/, "=", line)
      sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$file" 2>/dev/null || true
}

sentinel_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

sentinel_validate_policy_file() {
  local file="$1" display="${2:-$1}"
  local line line_no trimmed saw_root_key
  line_no=0
  saw_root_key=false

  if [ ! -s "$file" ]; then
    echo "::error::Malformed policy_file ${display}: file is empty" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"

    if [[ "$line" == *$'\t'* ]]; then
      echo "::error::Malformed policy_file ${display}:${line_no}: tabs are not supported; use spaces" >&2
      return 1
    fi

    trimmed=$(printf '%s' "$line" \
      | sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//; s/^[[:space:]]+|[[:space:]]+$//g')
    [ -z "$trimmed" ] && continue

    if [[ "$line" != [[:space:]]* ]]; then
      if ! [[ "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*.*$ ]]; then
        echo "::error::Malformed policy_file ${display}:${line_no}: expected top-level key mapping entry" >&2
        return 1
      fi
      saw_root_key=true
    else
      if ! [[ "$trimmed" =~ ^-([[:space:]].*)?$|^[^:]+:[[:space:]]*.*$ ]]; then
        echo "::error::Malformed policy_file ${display}:${line_no}: expected list item or map entry" >&2
        return 1
      fi
    fi
  done < "$file"

  if [ "$saw_root_key" != true ]; then
    echo "::error::Malformed policy_file ${display}: expected YAML mapping root" >&2
    return 1
  fi
}

sentinel_policy_file_for_config() {
  local config_file="$1"
  local policy_ref policy_path repo_root

  policy_ref=$(sentinel_yaml_get "$config_file" "policy_file" "")
  if [ -z "$policy_ref" ]; then
    echo ""
    return 0
  fi

  case "$policy_ref" in
    *.yaml|*.yml) ;;
    *)
      echo "::error::policy_file must be a YAML file (.yaml or .yml): ${policy_ref}" >&2
      return 1
      ;;
  esac

  case "$policy_ref" in
    /*)
      echo "::error::policy_file must be repository-relative, not absolute: ${policy_ref}" >&2
      return 1
      ;;
  esac

  repo_root=$(sentinel_repo_root)
  policy_path="${repo_root}/${policy_ref}"

  if [ ! -f "$policy_path" ]; then
    echo "::error::policy_file not found: ${policy_ref} (resolved to ${policy_path})" >&2
    return 1
  fi

  sentinel_validate_policy_file "$policy_path" "$policy_ref" || return 1
  echo "$policy_path"
}

sentinel_governance_source_file() {
  local config_file="$1" key="$2"
  local policy_file
  policy_file=$(sentinel_policy_file_for_config "$config_file") || return 1

  if [ -n "$policy_file" ] && sentinel_yaml_has_top_key "$policy_file" "$key"; then
    echo "$policy_file"
  else
    echo "$config_file"
  fi
}

sentinel_governance_get_array() {
  local config_file="$1" key="$2" source_file
  source_file=$(sentinel_governance_source_file "$config_file" "$key") || return 1
  sentinel_yaml_get_array "$source_file" "$key"
}

sentinel_governance_get_map() {
  local config_file="$1" key="$2" source_file
  source_file=$(sentinel_governance_source_file "$config_file" "$key") || return 1
  sentinel_yaml_get_map "$source_file" "$key"
}
