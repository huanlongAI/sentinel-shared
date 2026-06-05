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
LOOKBACK_DAYS="${REVIEW_GATE_AUDIT_LOOKBACK_DAYS:-}"
MERGED_SINCE="${REVIEW_GATE_AUDIT_MERGED_SINCE:-}"
EFFECTIVE_AFTER="${REVIEW_GATE_AUDIT_EFFECTIVE_AFTER:-}"

mkdir -p "$(dirname "$OUTPUT")"

resolve_merged_since() {
  if [ -n "$MERGED_SINCE" ]; then
    printf '%s' "$MERGED_SINCE"
    return
  fi

  if [ -z "$LOOKBACK_DAYS" ] || [ "$LOOKBACK_DAYS" = "all" ]; then
    return
  fi

  case "$LOOKBACK_DAYS" in
    *[!0-9]*)
      echo "Invalid REVIEW_GATE_AUDIT_LOOKBACK_DAYS: $LOOKBACK_DAYS" >&2
      exit 2
      ;;
  esac

  if date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi

  if date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi

  echo "Unable to compute REVIEW_GATE_AUDIT_LOOKBACK_DAYS on this platform" >&2
  exit 2
}

MERGED_SINCE="$(resolve_merged_since)"

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
    --arg lookback_days "$LOOKBACK_DAYS" \
    --arg merged_since "$MERGED_SINCE" \
    --arg effective_after "$EFFECTIVE_AFTER" \
    '{
      audit_id: $audit_id,
      generated_at: $generated_at,
      organization: $organization,
      lookback_days: $lookback_days,
      merged_since: $merged_since,
      effective_after: (if $effective_after == "" then null else $effective_after end),
      passed: false,
      checked: 0,
      violations: [],
      accounted_legacy_violations: [],
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

  collect_rest_repo_prs() {
    local repo out error_file pulls_file merged_pulls_file pr_json pr_number pr_file reviews_file comments_file comments_error_file next_file item_file per_page page page_count merged_count
    repo="$1"
    out="$2"
    error_file="$3"
    merged_pulls_file="$tmp/${repo}-rest-merged-pulls.json"
    per_page="100"
    page="1"

    case "$LIMIT" in
      ''|*[!0-9]*)
        printf 'Invalid REVIEW_GATE_AUDIT_LIMIT for REST fallback: %s\n' "$LIMIT" > "$error_file"
        return 1
        ;;
    esac

    if [ "$LIMIT" -lt 1 ]; then
      printf 'Invalid REVIEW_GATE_AUDIT_LIMIT for REST fallback: %s\n' "$LIMIT" > "$error_file"
      return 1
    fi

    printf '[]\n' > "$merged_pulls_file"
    while :; do
      pulls_file="$tmp/${repo}-rest-pulls-page-${page}.json"
      if ! gh_with_auth api "/repos/${ORG}/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=${per_page}&page=${page}" >"$pulls_file" 2>"$error_file"; then
        return 1
      fi

      page_count="$(jq 'length' "$pulls_file")"
      next_file="$tmp/${repo}-rest-merged-pulls-next.json"
      jq -c \
        --argjson limit "$LIMIT" \
        --slurpfile page_pulls "$pulls_file" \
        '. + [($page_pulls[0] // [])[] | select(.merged_at != null)] | .[:$limit]' \
        "$merged_pulls_file" > "$next_file"
      mv "$next_file" "$merged_pulls_file"

      merged_count="$(jq 'length' "$merged_pulls_file")"
      [ "$merged_count" -ge "$LIMIT" ] && break
      [ "$page_count" -lt "$per_page" ] && break
      page="$((page + 1))"
    done

    printf '[]\n' > "$out"
    while IFS= read -r pr_json; do
      [ -z "$pr_json" ] && continue
      pr_number="$(jq -r '.number' <<< "$pr_json")"
      pr_file="$tmp/${repo}-${pr_number}-rest-pr.json"
      reviews_file="$tmp/${repo}-${pr_number}-rest-reviews.json"
      comments_file="$tmp/${repo}-${pr_number}-rest-comments.json"
      comments_error_file="$tmp/${repo}-${pr_number}-rest-comments.err"
      item_file="$tmp/${repo}-${pr_number}-rest-item.json"
      printf '%s\n' "$pr_json" > "$pr_file"

      if ! gh_with_auth api "/repos/${ORG}/${repo}/pulls/${pr_number}/reviews" >"$reviews_file" 2>"$error_file"; then
        return 1
      fi

      if gh_with_auth api "/repos/${ORG}/${repo}/issues/${pr_number}/comments" >"$comments_file" 2>"$comments_error_file"; then
        jq -nc \
          --slurpfile pr "$pr_file" \
          --slurpfile reviews "$reviews_file" \
          --slurpfile comments "$comments_file" \
          '
            ($reviews[0] // []) as $raw_reviews
            | ($comments[0] // []) as $raw_comments
            | ($raw_reviews
              | map({
                  state: (.state // ""),
                  author: {login: (.author.login // .user.login // "")},
                  submittedAt: (.submittedAt // .submitted_at // "")
                })
              ) as $reviews_normalized
            | ($raw_comments
              | map({
                  body: (.body // ""),
                  author: {login: (.author.login // .user.login // "")},
                  createdAt: (.createdAt // .created_at // ""),
                  url: (.url // .html_url // "")
                })
              ) as $comments_normalized
            | $pr[0]
            | {
                number: .number,
                url: (.url // .html_url // ""),
                title: (.title // ""),
                mergedAt: (.mergedAt // .merged_at // ""),
                reviewDecision: (if ([$reviews_normalized[] | select(.state == "APPROVED")] | length) > 0 then "APPROVED" else "REVIEW_REQUIRED" end),
                headRefOid: (.headRefOid // .head.sha // ""),
                reviews: $reviews_normalized,
                comments: $comments_normalized
              }
          ' > "$item_file"
      else
        jq -nc \
          --slurpfile pr "$pr_file" \
          --slurpfile reviews "$reviews_file" \
          --rawfile comment_error "$comments_error_file" \
          '
            ($reviews[0] // []) as $raw_reviews
            | ($raw_reviews
              | map({
                  state: (.state // ""),
                  author: {login: (.author.login // .user.login // "")},
                  submittedAt: (.submittedAt // .submitted_at // "")
                })
              ) as $reviews_normalized
            | $pr[0]
            | {
                number: .number,
                url: (.url // .html_url // ""),
                title: (.title // ""),
                mergedAt: (.mergedAt // .merged_at // ""),
                reviewDecision: (if ([$reviews_normalized[] | select(.state == "APPROVED")] | length) > 0 then "APPROVED" else "REVIEW_REQUIRED" end),
                headRefOid: (.headRefOid // .head.sha // ""),
                reviews: $reviews_normalized,
                comments: [],
                comment_collection_error: $comment_error
              }
          ' > "$item_file"
      fi

      next_file="$tmp/${repo}-enriched-next.json"
      jq -c \
        --slurpfile pr "$item_file" \
        '. + [$pr[0]]' \
        "$out" > "$next_file"
      mv "$next_file" "$out"
    done < <(jq -c '.[]' "$merged_pulls_file")
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
      if collect_rest_repo_prs "$repo" "$enriched_file" "$tmp/rest-fallback.err"; then
        next_file="$tmp/repositories-next.json"
        jq -c \
          --arg name "$repo" \
          --slurpfile pull_requests "$enriched_file" \
          '. + [{name: $name, pull_requests: $pull_requests[0]}]' \
          "$repositories_file" > "$next_file"
        mv "$next_file" "$repositories_file"
        continue
      fi

      next_file="$tmp/repositories-next.json"
      jq -c \
        --arg name "$repo" \
        --rawfile error "$tmp/pr-list.err" \
        --rawfile rest_error "$tmp/rest-fallback.err" \
        '. + [{name: $name, pull_requests: [], collection_error: ("GraphQL pr list: " + $error + "REST fallback: " + $rest_error)}]' \
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
    --arg lookback_days "$LOOKBACK_DAYS" \
    --arg merged_since "$MERGED_SINCE" \
    --arg effective_after "$EFFECTIVE_AFTER" \
    --argjson actors "$actors_json" \
    '
      def merged_at($pr):
        ($pr.mergedAt // $pr.merged_at // "");

      def in_merged_window($pr):
        ($merged_since == "")
        or ((merged_at($pr) | fromdateiso8601? // 0) >= ($merged_since | fromdateiso8601? // 0));

      def is_pre_effective($pr):
        ($effective_after != "")
        and ((merged_at($pr) | fromdateiso8601? // 0) < ($effective_after | fromdateiso8601? // 0));

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
        | select(merged_at(.) != "")
        | select(in_merged_window(.))
        | select((.reviewDecision // .review_decision // "") == "REVIEW_REQUIRED")
        | select(approved_review_count(.) == 0)
        | override_comment(.) as $override
        | select($override == null)
        | select(is_pre_effective(.) | not)
        | {
            repo: $repo,
            number: .number,
            url: .url,
            mergedAt: merged_at(.),
            reviewDecision: (.reviewDecision // .review_decision // ""),
            approved_reviews: approved_review_count(.),
            reason: "merged_review_required_without_approval_or_override"
          }
      ] as $violations
      | [
        (.repositories // [])[]
        | (.name // .repo // "") as $repo
        | (.pull_requests // [])[]
        | select(merged_at(.) != "")
        | select(in_merged_window(.))
        | select((.reviewDecision // .review_decision // "") == "REVIEW_REQUIRED")
        | select(approved_review_count(.) == 0)
        | override_comment(.) as $override
        | select($override == null)
        | select(is_pre_effective(.))
        | {
            repo: $repo,
            number: .number,
            url: .url,
            mergedAt: merged_at(.),
            reviewDecision: (.reviewDecision // .review_decision // ""),
            approved_reviews: approved_review_count(.),
            source: "pre_effective_review_gate_audit_baseline",
            effective_after: $effective_after
          }
      ] as $accounted_legacy_violations
      | [
        (.repositories // [])[]
        | (.name // .repo // "") as $repo
        | (.pull_requests // [])[]
        | select(merged_at(.) != "")
        | select(in_merged_window(.))
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
        | select(merged_at(.) != "")
        | select(in_merged_window(.))
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
          lookback_days: $lookback_days,
          merged_since: $merged_since,
          effective_after: (if $effective_after == "" then null else $effective_after end),
          repositories: [(.repositories // [])[] | (.name // .repo // "")],
          passed: (($violations | length) == 0 and ($collection_errors | length) == 0),
          checked: ($checked_prs | length),
          violations: $violations,
          accounted_legacy_violations: $accounted_legacy_violations,
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
    jq -r '"Checked: \(.checked) | Violations: \(.violations | length) | Legacy accounted: \(.accounted_legacy_violations | length) | Accounted overrides: \(.accounted_overrides | length)"' "$OUTPUT"
    jq -r '"Merged since: \((.merged_since // "") | if . == "" then "full audit" else . end)"' "$OUTPUT"
    jq -r '"Effective after: \((.effective_after // "") | if . == "" then "none" else . end)"' "$OUTPUT"
    echo ""
    if jq -e '(.violations | length) > 0' "$OUTPUT" >/dev/null; then
      echo "| Repo | PR | Reason |"
      echo "|---|---:|---|"
      jq -r '.violations[] | "| \(.repo) | [#\(.number)](\(.url)) | \(.reason) |"' "$OUTPUT"
    fi
    if jq -e '(.collection_errors | length) > 0' "$OUTPUT" >/dev/null; then
      echo ""
      echo "| Repo | Collection error |"
      echo "|---|---|"
      jq -r '.collection_errors[] | "| \(.repo) | \((.reason // "") | gsub("[\r\n]+"; " ")) |"' "$OUTPUT"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if jq -e '.passed == true' "$OUTPUT" >/dev/null; then
  echo "Review gate audit passed"
  exit 0
fi

echo "Review gate audit failed"
jq -r '.violations[]? | "::error::\(.repo)#\(.number) \(.reason)"' "$OUTPUT"
jq -r '.collection_errors[]? | "::error::\(.repo) collection_error \((.reason // "") | gsub("[\r\n]+"; " "))"' "$OUTPUT"
exit 1
