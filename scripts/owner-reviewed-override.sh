#!/usr/bin/env bash
set -euo pipefail

# Detects an explicit GitHub owner-reviewed override for an LLM ESCALATE result.
# This never overrides deterministic failures, LLM FAIL, provider errors, or a
# stale comment from a previous PR head SHA.

CONFIG_FILE="${CONFIG_FILE:-.sentinel/config.yaml}"
RESULTS_DIR="${RESULTS_DIR:-.sentinel/results}"
REQUIRED_DETERMINISTIC_RESULT_FILES="${REQUIRED_DETERMINISTIC_RESULT_FILES:-}"
OWNER_REVIEWED_COMMENTS_FILE="${OWNER_REVIEWED_COMMENTS_FILE:-}"
PR_NUMBER="${PR_NUMBER:-}"
HEAD_SHA="${HEAD_SHA:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/policy-loader.sh
source "$SCRIPT_DIR/policy-loader.sh"

mkdir -p "$RESULTS_DIR"
OVERRIDE_FILE="$RESULTS_DIR/owner-reviewed-override.json"
rm -f "$OVERRIDE_FILE"

echo "Owner-reviewed override check"

actors=$(sentinel_governance_get_array "$CONFIG_FILE" "owner_reviewed_override_actors" 2>/dev/null || true)
if [ -z "$actors" ]; then
  echo "No owner_reviewed_override_actors configured; override disabled"
  exit 0
fi

if [ -z "$PR_NUMBER" ] || [ -z "$HEAD_SHA" ]; then
  echo "PR_NUMBER or HEAD_SHA not available; override disabled"
  exit 0
fi

LLM_FILE="$RESULTS_DIR/llm-review.json"
if [ ! -f "$LLM_FILE" ]; then
  echo "No llm-review.json found; override disabled"
  exit 0
fi

llm_verdict=$(jq -r '.verdict // ""' "$LLM_FILE" 2>/dev/null || echo "")
llm_passed=$(jq -r '.passed // false' "$LLM_FILE" 2>/dev/null || echo "false")
if [ "$llm_verdict" != "ESCALATE" ] || [ "$llm_passed" = "true" ]; then
  echo "LLM verdict is not failed ESCALATE; override disabled"
  exit 0
fi

if [ -z "$REQUIRED_DETERMINISTIC_RESULT_FILES" ]; then
  REQUIRED_DETERMINISTIC_RESULT_FILES=$(find "$RESULTS_DIR" -maxdepth 1 -name "d*-*.json" -type f -exec basename {} \; | sort)
fi

for required_result in $REQUIRED_DETERMINISTIC_RESULT_FILES; do
  [ -z "$required_result" ] && continue
  result_path="$RESULTS_DIR/$required_result"
  if [ ! -f "$result_path" ]; then
    echo "Required deterministic result missing: $required_result; override disabled"
    exit 0
  fi
  passed=$(jq -r '.passed // false' "$result_path" 2>/dev/null || echo "false")
  if [ "$passed" != "true" ]; then
    echo "Deterministic result failed: $required_result; override disabled"
    exit 0
  fi
done

comments_json=""
if [ -n "$OWNER_REVIEWED_COMMENTS_FILE" ]; then
  if [ ! -f "$OWNER_REVIEWED_COMMENTS_FILE" ]; then
    echo "OWNER_REVIEWED_COMMENTS_FILE not found; override disabled"
    exit 0
  fi
  comments_json=$(cat "$OWNER_REVIEWED_COMMENTS_FILE")
else
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ] || [ -z "$GITHUB_REPOSITORY" ]; then
    echo "GitHub token or repository not available; override disabled"
    exit 0
  fi
  if ! comments_json=$(GH_TOKEN="$token" gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate 2>/dev/null); then
    echo "Unable to read PR comments; override disabled"
    exit 0
  fi
fi

actors_json=$(printf '%s\n' "$actors" | jq -R . | jq -s .)
match=$(
  jq -r \
    --arg head "$HEAD_SHA" \
    --argjson actors "$actors_json" \
    '
      .[]
      | {
          body: (.body // ""),
          login: (.user.login // .author.login // ""),
          association: (.author_association // .authorAssociation // ""),
          url: (.html_url // .url // "")
        }
      | select(.login as $login | $actors | index($login))
      | select(.body | test("sentinel-owner-reviewed-override:[[:space:]]*approved"; "i"))
      | select(.body | test("(^|\\n)[[:space:]]*(head_sha|head):[[:space:]]*" + $head + "([[:space:]]|$)"; "i"))
      | select(.body | test("deterministic[ _-]*checks:[[:space:]]*PASS"; "i"))
      | select(.body | test("llm[-_ ]?review:[[:space:]]*ESCALATE"; "i"))
      | select(.body | test("follow[-_ ]?up:[[:space:]]*https://"; "i"))
      | [.login, .association, .url]
      | @tsv
    ' <<< "$comments_json" 2>/dev/null | head -n 1
)

if [ -z "$match" ]; then
  echo "No valid owner-reviewed override comment found"
  exit 0
fi

IFS=$'\t' read -r actor author_association comment_url <<< "$match"

jq -n \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg head_sha "$HEAD_SHA" \
  --arg actor "$actor" \
  --arg author_association "$author_association" \
  --arg comment_url "$comment_url" \
  '{
    review_id: "owner-reviewed-override",
    check_name: "Owner Reviewed Override",
    status: "accepted",
    passed: true,
    overrides_review_id: "llm-review",
    overrides_verdict: "ESCALATE",
    scope: "llm-review",
    head_sha: $head_sha,
    actor: $actor,
    author_association: $author_association,
    comment_url: $comment_url,
    reason: "LLM ESCALATE accepted by owner-reviewed GitHub SSOT evidence",
    timestamp: $timestamp
  }' > "$OVERRIDE_FILE"

echo "Owner-reviewed override accepted by ${actor} for HEAD ${HEAD_SHA}"
