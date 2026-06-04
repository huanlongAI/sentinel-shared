#!/usr/bin/env bash
set -euo pipefail

# Post-merge review gate audit.
#
# This is a monitoring surface for GitHub protection drift: it does not merge,
# update, or bypass anything. It flags merged PRs that still report
# REVIEW_REQUIRED without an approved review or an explicit owner-recorded
# review gate override.

ORG="${REVIEW_GATE_AUDIT_ORG:-huanlongAI}"
REPOS="${REVIEW_GATE_AUDIT_REPOS:-hl-platform hl-framework hl-factory hl-dispatch hl-contracts hl-console-native team-memory}"
LIMIT="${REVIEW_GATE_AUDIT_LIMIT:-30}"
OUTPUT="${REVIEW_GATE_AUDIT_OUTPUT:-.sentinel/results/review-gate-audit.json}"
FIXTURE="${REVIEW_GATE_AUDIT_FIXTURE:-}"
OVERRIDE_ACTORS="${REVIEW_GATE_AUDIT_OVERRIDE_ACTORS:-}"

mkdir -p "$(dirname "$OUTPUT")"

actors_json="$(
  if [ -n "$OVERRIDE_ACTORS" ]; then
    printf '%s\n' $OVERRIDE_ACTORS | jq -R . | jq -s .
  else
    printf '[]'
  fi
)"

write_collection_error() {
  local reason="$1"
  jq -n \
    --arg audit_id "review-gate-audit" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg organization "$ORG" \
    --arg reason "$reason" \
    '{
      audit_id: $audit_id,
      generated_at: $generated_at,
      organization: $organization,
      passed: false,
      checked: 0,
      violations: [],
      accounted_overrides: [],
      collection_errors: [{reason: $reason}]
    }' > "$OUTPUT"
}

collect_live_prs() {
  local token tmp repositories_file next_file repo prs_file enriched_file pr_file comments_file pr_number pr_json
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  gh_with_auth() {
    if [ -n "$token" ]; then
      GH_TOKEN="$token" gh "$@"
    else
      gh "$@"
    fi
  }

  tmp="$(mktemp -d)"
  repositories_file="$tmp/repositories.json"
  printf '[]\n' > "$repositories_file"

  for repo in $REPOS; do
    prs_file="$tmp/${repo}-prs.json"
    enriched_file="$tmp/${repo}-enriched.json"
    printf '[]\n' > "$enriched_file"

    if ! gh_with_auth pr list \
      --repo "${ORG}/${repo}" \
      --state merged \
      --limit "$LIMIT" \
      --json number,title,url,mergedAt,reviewDecision,reviews,headRefOid >"$prs_file" 2>"$tmp/pr-list.err"; then
      next_file="$tmp/repositories-next.json"
      jq -c \
        --arg name "$repo" \
        --rawfile error "$tmp/pr-list.err" \
        '. + [{name: $name, pull_requests: [], collection_error: $error}]' \
        "$repositories_file" > "$next_file"
      mv "$next_file" "$repositories_file"
      continue
    fi

    while IFS= read -r pr_json; do
      [ -z "$pr_json" ] && continue
      pr_number="$(jq -r '.number' <<< "$pr_json")"
      pr_file="$tmp/${repo}-${pr_number}-pr.json"
      comments_file="$tmp/${repo}-${pr_number}-comments.json"
      printf '%s\n' "$pr_json" > "$pr_file"

      if gh_with_auth pr view "$pr_number" \
        --repo "${ORG}/${repo}" \
        --json comments \
        --jq '.comments' >"$comments_file" 2>"$tmp/pr-view.err"; then
        next_file="$tmp/${repo}-enriched-next.json"
        jq -c \
          --slurpfile pr "$pr_file" \
          --slurpfile comments "$comments_file" \
          '. + [($pr[0] + {comments: $comments[0]})]' \
          "$enriched_file" > "$next_file"
        mv "$next_file" "$enriched_file"
      else
        next_file="$tmp/${repo}-enriched-next.json"
        jq -c \
          --slurpfile pr "$pr_file" \
          --rawfile error "$tmp/pr-view.err" \
          '. + [($pr[0] + {comments: [], comment_collection_error: $error})]' \
          "$enriched_file" > "$next_file"
        mv "$next_file" "$enriched_file"
      fi
    done < <(jq -c '.[]' "$prs_file")

    next_file="$tmp/repositories-next.json"
    jq -c \
      --arg name "$repo" \
      --slurpfile pull_requests "$enriched_file" \
      '. + [{name: $name, pull_requests: $pull_requests[0]}]' \
      "$repositories_file" > "$next_file"
    mv "$next_file" "$repositories_file"
  done

  jq -n --slurpfile repositories "$repositories_file" '{repositories: $repositories[0]}'
}

if [ -n "$FIXTURE" ]; then
  input_json="$(cat "$FIXTURE")"
else
  if ! input_json="$(collect_live_prs)"; then
    exit 2
  fi
fi

result_json="$(
  jq \
    --arg audit_id "review-gate-audit" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg organization "$ORG" \
    --argjson actors "$actors_json" \
    '
      def login_of($comment):
        ($comment.author.login // $comment.user.login // "");

      def approved_review_count($pr):
        [($pr.reviews // [])[] | select((.state // "") == "APPROVED")] | length;

      def override_comment($pr):
        (($pr.headRefOid // $pr.head_sha // "") as $head
        | [($pr.comments // [])[]
          | {
              login: login_of(.),
              body: (.body // ""),
              url: (.url // .html_url // ""),
              createdAt: (.createdAt // .created_at // "")
            }
          | .login as $login
          | select($actors | index($login))
          | select(.body | test("sentinel-review-gate-override:[[:space:]]*approved"; "i"))
          | select(.body | test("(^|\\n)[[:space:]]*(head_sha|head):[[:space:]]*" + $head + "([[:space:]]|$)"; "i"))
          | select(.body | test("review_required:[[:space:]]*acknowledged"; "i"))
          | select(.body | test("reason:[[:space:]]*.+"; "i"))
        ][0] // null);

      [
        (.repositories // [])[]
        | (.name // .repo // "") as $repo
        | (.pull_requests // [])[]
        | select((.mergedAt // .merged_at // "") != "")
        | select((.reviewDecision // .review_decision // "") == "REVIEW_REQUIRED")
        | select(approved_review_count(.) == 0)
        | override_comment(.) as $override
        | select($override == null)
        | {
            repo: $repo,
            number: .number,
            url: .url,
            mergedAt: (.mergedAt // .merged_at // ""),
            reviewDecision: (.reviewDecision // .review_decision // ""),
            approved_reviews: approved_review_count(.),
            reason: "merged_review_required_without_approval_or_override"
          }
      ] as $violations
      | [
        (.repositories // [])[]
        | (.name // .repo // "") as $repo
        | (.pull_requests // [])[]
        | select((.mergedAt // .merged_at // "") != "")
        | select((.reviewDecision // .review_decision // "") == "REVIEW_REQUIRED")
        | select(approved_review_count(.) == 0)
        | override_comment(.) as $override
        | select($override != null)
        | {
            repo: $repo,
            number: .number,
            url: .url,
            source: "structured_review_gate_override",
            actor: $override.login,
            comment_url: $override.url
          }
      ] as $accounted_overrides
      | [
        (.repositories // [])[]
        | (.pull_requests // [])[]
        | select((.mergedAt // .merged_at // "") != "")
      ] as $checked_prs
      | [
        (.repositories // [])[]
        | select(.collection_error)
        | {repo: (.name // .repo // ""), reason: .collection_error}
      ] as $collection_errors
      | {
          audit_id: $audit_id,
          generated_at: $generated_at,
          organization: $organization,
          repositories: [(.repositories // [])[] | (.name // .repo // "")],
          passed: (($violations | length) == 0 and ($collection_errors | length) == 0),
          checked: ($checked_prs | length),
          violations: $violations,
          accounted_overrides: $accounted_overrides,
          collection_errors: $collection_errors
        }
    ' <<< "$input_json"
)"

printf '%s\n' "$result_json" > "$OUTPUT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Review Gate Audit"
    echo ""
    jq -r '"Checked: \(.checked) | Violations: \(.violations | length) | Accounted overrides: \(.accounted_overrides | length)"' "$OUTPUT"
    echo ""
    if jq -e '(.violations | length) > 0' "$OUTPUT" >/dev/null; then
      echo "| Repo | PR | Reason |"
      echo "|---|---:|---|"
      jq -r '.violations[] | "| \(.repo) | [#\(.number)](\(.url)) | \(.reason) |"' "$OUTPUT"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if jq -e '.passed == true' "$OUTPUT" >/dev/null; then
  echo "Review gate audit passed"
  exit 0
fi

echo "Review gate audit failed"
jq -r '.violations[]? | "::error::\(.repo)#\(.number) \(.reason)"' "$OUTPUT"
exit 1
