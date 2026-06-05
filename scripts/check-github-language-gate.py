#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
LATIN_WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
URL_RE = re.compile(r"https?://\S+")
FENCED_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)
ISSUE_URL_RE = re.compile(r"/issues/(\d+)(?:#|$)")

MIN_BODY_CJK_CHARS = 6
MIN_BODY_CJK_RATIO = 0.2
LATIN_HEAVY_WORDS = 12

OWNER_CONFIRMATION_ROOTS = (
    "owner_confirmation_response_v1:",
    "frontend_owner_confirmation:",
)
INTERNAL_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}


def has_chinese(text):
    return bool(CJK_RE.search(text or ""))


def chinese_signal_too_weak(text):
    normalized = URL_RE.sub(" ", text or "")
    cjk_count = len(CJK_RE.findall(normalized))
    if cjk_count == 0:
        return False

    prose_for_latin_count = FENCED_CODE_BLOCK_RE.sub(" ", normalized)
    latin_word_count = len(LATIN_WORD_RE.findall(prose_for_latin_count))
    if latin_word_count < LATIN_HEAVY_WORDS:
        return False

    cjk_ratio = cjk_count / (cjk_count + latin_word_count)
    return cjk_count < MIN_BODY_CJK_CHARS or cjk_ratio < MIN_BODY_CJK_RATIO


def is_structured_owner_yaml(text):
    stripped = (text or "").lstrip()
    return any(stripped.startswith(root) for root in OWNER_CONFIRMATION_ROOTS)


def actor_scope(event, target):
    user_type = ((target.get("user") or {}).get("type") or "").lower()
    if user_type == "bot":
        return "internal"

    association = (target.get("author_association") or "").upper()
    if association in INTERNAL_ASSOCIATIONS:
        return "internal"
    if association:
        return "external"
    return "internal"


def validate_issue(issue):
    errors = []
    title = issue.get("title") or ""
    body = issue.get("body") or ""

    if not has_chinese(title):
        errors.append("title_missing_chinese")
    if body.strip() and not has_chinese(body):
        errors.append("body_missing_chinese")
    elif body.strip() and chinese_signal_too_weak(body):
        errors.append("body_chinese_ratio_too_low")

    return {
        "kind": "issue",
        "target_url": issue.get("html_url") or "",
        "structured_yaml_allowed": False,
        "violations": errors,
    }


def validate_comment(comment):
    body = comment.get("body") or ""
    structured_yaml_allowed = is_structured_owner_yaml(body)
    errors = []

    if not structured_yaml_allowed and not has_chinese(body):
        errors.append("comment_missing_chinese")
    elif not structured_yaml_allowed and chinese_signal_too_weak(body):
        errors.append("comment_chinese_ratio_too_low")

    return {
        "kind": "issue_comment",
        "target_url": comment.get("html_url") or "",
        "structured_yaml_allowed": structured_yaml_allowed,
        "violations": errors,
    }


def validate_event(event, enforcement_mode):
    if "comment" in event:
        target = event.get("comment") or {}
        result = validate_comment(target)
    elif "issue" in event:
        target = event.get("issue") or {}
        result = validate_issue(target)
    else:
        target = {}
        result = {
            "kind": "unsupported",
            "target_url": "",
            "structured_yaml_allowed": False,
            "violations": ["unsupported_event_payload"],
        }

    scope = actor_scope(event, target)
    violations = result.pop("violations")
    if violations and scope == "external":
        status = "warn"
        errors = []
        warnings = violations
    elif violations:
        status = "failed"
        errors = violations
        warnings = []
    else:
        status = "passed"
        errors = []
        warnings = []

    result.update(
        {
            "actor_scope": scope,
            "audit_mode": enforcement_mode == "audit",
            "enforcement_mode": enforcement_mode,
            "errors": errors,
            "status": status,
            "target_issue_number": target_issue_number(event, result["target_url"]),
            "warnings": warnings,
        }
    )
    return result


def target_issue_number(event, target_url):
    issue = event.get("issue") or {}
    number = issue.get("number")
    if number is not None:
        return str(number)

    match = ISSUE_URL_RE.search(target_url or "")
    if match:
        return match.group(1)

    return ""


def write_github_output(output_path, result):
    values = {
        "actor_scope": result["actor_scope"],
        "errors": ",".join(result["errors"]),
        "status": result["status"],
        "target_issue_number": result["target_issue_number"],
        "target_url": result["target_url"],
        "warnings": ",".join(result["warnings"]),
    }
    with Path(output_path).open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check GitHub issue/comment Chinese language gate")
    parser.add_argument("--event-path", required=True)
    parser.add_argument("--enforcement-mode", choices=("audit", "enforce"), default="audit")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    event = json.loads(Path(args.event_path).read_text(encoding="utf-8"))
    result = validate_event(event, args.enforcement_mode)
    if args.github_output:
        write_github_output(args.github_output, result)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))

    if args.enforcement_mode == "enforce" and result["status"] == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
