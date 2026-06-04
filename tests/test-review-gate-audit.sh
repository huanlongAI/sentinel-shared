#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/review-gate-audit.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_reviewless_fixture() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "repositories": [
    {
      "name": "hl-dispatch",
      "pull_requests": [
        {
          "number": 191,
          "url": "https://github.com/huanlongAI/hl-dispatch/pull/191",
          "title": "fix: enforce Chinese issue body signal",
          "mergedAt": "2026-06-04T01:46:46Z",
          "reviewDecision": "REVIEW_REQUIRED",
          "headRefOid": "1111111111111111111111111111111111111111",
          "reviews": [],
          "comments": []
        }
      ]
    }
  ]
}
JSON
}

write_approved_fixture() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "repositories": [
    {
      "name": "hl-dispatch",
      "pull_requests": [
        {
          "number": 192,
          "url": "https://github.com/huanlongAI/hl-dispatch/pull/192",
          "title": "fix: reviewed governance change",
          "mergedAt": "2026-06-04T02:00:00Z",
          "reviewDecision": "APPROVED",
          "headRefOid": "2222222222222222222222222222222222222222",
          "reviews": [
            {"state": "APPROVED", "author": {"login": "gate-reviewer"}}
          ],
          "comments": []
        }
      ]
    }
  ]
}
JSON
}

write_override_fixture() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "repositories": [
    {
      "name": "hl-dispatch",
      "pull_requests": [
        {
          "number": 193,
          "url": "https://github.com/huanlongAI/hl-dispatch/pull/193",
          "title": "fix: owner-accounted governance bypass",
          "mergedAt": "2026-06-04T03:00:00Z",
          "reviewDecision": "REVIEW_REQUIRED",
          "headRefOid": "3333333333333333333333333333333333333333",
          "reviews": [],
          "comments": [
            {
              "body": "sentinel-review-gate-override: approved\nhead_sha: 3333333333333333333333333333333333333333\nreview_required: acknowledged\nreason: Founder/owner recorded bypass evidence",
              "author": {"login": "gate-owner"},
              "createdAt": "2026-06-04T03:01:00Z",
              "url": "https://github.com/huanlongAI/hl-dispatch/pull/193#issuecomment-1"
            }
          ]
        }
      ]
    }
  ]
}
JSON
}

test_reviewless_merge_fails_audit() {
  local tmp output code
  tmp="$(mktemp -d)"
  write_reviewless_fixture "$tmp/fixture.json"

  set +e
  REVIEW_GATE_AUDIT_FIXTURE="$tmp/fixture.json" \
    REVIEW_GATE_AUDIT_OUTPUT="$tmp/result.json" \
    bash "$SCRIPT" >"$tmp/stdout" 2>"$tmp/stderr"
  code=$?
  set -e

  [ "$code" -ne 0 ] || fail "reviewless merged PR must fail audit"
  [ -f "$tmp/result.json" ] || fail "review-gate audit must write JSON output"
  jq -e '
    .passed == false
    and (.violations | length) == 1
    and .violations[0].repo == "hl-dispatch"
    and .violations[0].number == 191
    and .violations[0].reason == "merged_review_required_without_approval_or_override"
  ' "$tmp/result.json" >/dev/null ||
    fail "reviewless merge violation was not recorded"
}

test_approved_review_passes_audit() {
  local tmp
  tmp="$(mktemp -d)"
  write_approved_fixture "$tmp/fixture.json"

  REVIEW_GATE_AUDIT_FIXTURE="$tmp/fixture.json" \
    REVIEW_GATE_AUDIT_OUTPUT="$tmp/result.json" \
    bash "$SCRIPT" >/dev/null

  jq -e '
    .passed == true
    and (.violations | length) == 0
    and .checked == 1
  ' "$tmp/result.json" >/dev/null ||
    fail "approved merged PR should pass audit"
}

test_structured_owner_override_accounts_for_reviewless_merge() {
  local tmp
  tmp="$(mktemp -d)"
  write_override_fixture "$tmp/fixture.json"

  REVIEW_GATE_AUDIT_FIXTURE="$tmp/fixture.json" \
    REVIEW_GATE_AUDIT_OUTPUT="$tmp/result.json" \
    REVIEW_GATE_AUDIT_OVERRIDE_ACTORS="gate-owner" \
    bash "$SCRIPT" >/dev/null

  jq -e '
    .passed == true
    and (.violations | length) == 0
    and (.accounted_overrides | length) == 1
    and .accounted_overrides[0].repo == "hl-dispatch"
    and .accounted_overrides[0].number == 193
    and .accounted_overrides[0].source == "structured_review_gate_override"
  ' "$tmp/result.json" >/dev/null ||
    fail "structured owner override should account for reviewless merge"
}

test_live_collection_uses_gh_cli_auth_without_token_env() {
  local tmp code
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
[
  {
    "number": 191,
    "url": "https://github.com/huanlongAI/hl-dispatch/pull/191",
    "title": "fix: enforce Chinese issue body signal",
    "mergedAt": "2026-06-04T01:46:46Z",
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "1111111111111111111111111111111111111111",
    "reviews": []
  }
]
JSON
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat <<'JSON'
[]
JSON
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
SH
  chmod +x "$tmp/bin/gh"

  set +e
  PATH="$tmp/bin:$PATH" \
    GH_TOKEN="" \
    GITHUB_TOKEN="" \
    REVIEW_GATE_AUDIT_REPOS="hl-dispatch" \
    REVIEW_GATE_AUDIT_LIMIT="1" \
    REVIEW_GATE_AUDIT_OUTPUT="$tmp/result.json" \
    bash "$SCRIPT" >/dev/null
  code=$?
  set -e

  [ "$code" -eq 1 ] || fail "live audit should use gh CLI auth and fail on reviewless PR, got exit $code"
  jq -e '
    .checked == 1
    and (.collection_errors | length) == 0
    and (.violations | length) == 1
    and .violations[0].number == 191
  ' "$tmp/result.json" >/dev/null ||
    fail "live gh collection did not audit fake merged PR"
}

test_reviewless_merge_fails_audit
test_approved_review_passes_audit
test_structured_owner_override_accounts_for_reviewless_merge
test_live_collection_uses_gh_cli_auth_without_token_env

echo "review-gate audit tests passed"
