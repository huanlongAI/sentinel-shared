#!/usr/bin/env python3
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from datetime import date
from pathlib import Path


CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
ENGLISH_WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")
FENCED_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
URL_RE = re.compile(r"https?://\S+")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)

DEFAULT_TARGET_PATTERNS = [
    "docs/**/*.md",
    "deliverables/**/*.md",
    "README.md",
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
]
REQUIRED_SECTION_HEADINGS = ("中文摘要", "术语说明")
ALLOWLIST_REQUIRED_FIELDS = ("path", "reason", "approval_ref", "expires_on")


def run_git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def ref_points_at_head(ref, cwd):
    ref_result = run_git(["rev-parse", "--verify", ref], cwd)
    head_result = run_git(["rev-parse", "--verify", "HEAD"], cwd)
    return (
        ref_result.returncode == 0
        and head_result.returncode == 0
        and ref_result.stdout.strip() == head_result.stdout.strip()
    )


def repo_root():
    result = run_git(["rev-parse", "--show-toplevel"], Path.cwd())
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def strip_quotes(value):
    value = (value or "").strip()
    if "#" in value:
        value = value.split("#", 1)[0].strip()
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    return value


def parse_bool(value, default=False):
    value = str(value).strip().lower()
    if value in {"true", "yes", "1", "on"}:
        return True
    if value in {"false", "no", "0", "off"}:
        return False
    return default


def parse_float(value, default):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_doc_readability_config(config_path):
    config = {
        "mode": "disabled",
        "target_patterns": DEFAULT_TARGET_PATTERNS,
        "allowlist_file": "",
        "min_cjk_ratio": 0.2,
        "min_cjk_chars": 20,
        "min_english_words": 80,
        "min_changed_lines": 20,
        "require_sections": True,
    }
    path = Path(config_path)
    if not path.exists():
        return config

    lines = path.read_text(encoding="utf-8").splitlines()
    in_section = False
    current_list_key = None
    section_values = {}
    list_values = {}

    for raw_line in lines:
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if indent == 0:
            in_section = stripped.startswith("doc_readability:")
            current_list_key = None
            continue

        if not in_section:
            continue

        if indent == 2 and re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:", stripped):
            key, value = stripped.split(":", 1)
            key = key.strip()
            value = strip_quotes(value)
            if value:
                section_values[key] = value
                current_list_key = None
            else:
                list_values.setdefault(key, [])
                current_list_key = key
            continue

        if indent >= 4 and current_list_key and stripped.startswith("- "):
            list_values.setdefault(current_list_key, []).append(strip_quotes(stripped[2:]))

    if "mode" in section_values:
        config["mode"] = section_values["mode"].lower()
    if "allowlist_file" in section_values:
        config["allowlist_file"] = section_values["allowlist_file"]
    if "min_cjk_ratio" in section_values:
        config["min_cjk_ratio"] = parse_float(section_values["min_cjk_ratio"], config["min_cjk_ratio"])
    if "min_cjk_chars" in section_values:
        config["min_cjk_chars"] = parse_int(section_values["min_cjk_chars"], config["min_cjk_chars"])
    if "min_english_words" in section_values:
        config["min_english_words"] = parse_int(
            section_values["min_english_words"], config["min_english_words"]
        )
    if "min_changed_lines" in section_values:
        config["min_changed_lines"] = parse_int(
            section_values["min_changed_lines"], config["min_changed_lines"]
        )
    if "require_sections" in section_values:
        config["require_sections"] = parse_bool(section_values["require_sections"], True)
    if list_values.get("target_patterns"):
        config["target_patterns"] = list_values["target_patterns"]

    if config["mode"] not in {"disabled", "audit", "enforce"}:
        config["mode"] = "disabled"
    return config


def parse_allowlist_file(path):
    entries = []
    warnings = []
    allowlist_path = Path(path)
    if not path:
        return entries, warnings
    if not allowlist_path.exists():
        warnings.append(
            {
                "code": "allowlist_file_missing",
                "path": str(allowlist_path),
                "message": f"allowlist file not found: {allowlist_path}",
            }
        )
        return entries, warnings

    current = None
    for raw_line in allowlist_path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or stripped == "allowlist:":
            continue
        if stripped.startswith("- "):
            if current is not None:
                entries.append(current)
            current = {}
            item = stripped[2:].strip()
            if ":" in item:
                key, value = item.split(":", 1)
                current[key.strip()] = strip_quotes(value)
            continue
        if current is not None and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[key.strip()] = strip_quotes(value)
    if current is not None:
        entries.append(current)

    valid_entries = []
    for entry in entries:
        missing = [field for field in ALLOWLIST_REQUIRED_FIELDS if not entry.get(field)]
        if missing:
            warnings.append(
                {
                    "code": "allowlist_entry_invalid",
                    "path": entry.get("path", ""),
                    "message": f"allowlist entry missing fields: {', '.join(missing)}",
                }
            )
            continue
        valid_entries.append(entry)
    return valid_entries, warnings


def is_allowlisted(path, entries, today):
    for entry in entries:
        if entry.get("path") != path:
            continue
        try:
            expires_on = date.fromisoformat(entry.get("expires_on", ""))
        except ValueError:
            return False, {
                "code": "allowlist_entry_invalid_date",
                "path": path,
                "message": f"allowlist expires_on is invalid for {path}",
            }
        if expires_on < today:
            return False, None
        return True, {
            "code": "doc_readability_allowlisted",
            "path": path,
            "approval_ref": entry["approval_ref"],
            "expires_on": entry["expires_on"],
            "message": f"{path} is temporarily allowlisted until {entry['expires_on']}",
        }
    return False, None


def diff_arg_candidates(cwd):
    base_ref = os.environ.get("BASE_REF") or os.environ.get("GITHUB_BASE_REF")
    candidates = []
    if base_ref:
        origin_ref = f"origin/{base_ref}"
        if not ref_points_at_head(origin_ref, cwd):
            candidates.append([f"{origin_ref}...HEAD"])
        if not ref_points_at_head(base_ref, cwd):
            candidates.append([f"{base_ref}...HEAD"])
    result = run_git(["rev-parse", "--verify", "HEAD~1"], cwd)
    if result.returncode == 0:
        candidates.append(["HEAD~1", "HEAD"])
    candidates.append(["--cached"])
    return candidates


def changed_files(cwd):
    name_status = None
    numstat = None
    for args in diff_arg_candidates(cwd):
        name_status = run_git(["diff", "--name-status", "--diff-filter=ACMRT", *args], cwd)
        numstat = run_git(["diff", "--numstat", "--diff-filter=ACMRT", *args], cwd)
        if name_status.returncode == 0 and numstat.returncode == 0:
            break

    files = {}
    if name_status and name_status.returncode == 0:
        for line in name_status.stdout.splitlines():
            parts = line.split("\t")
            if not parts:
                continue
            status = parts[0]
            path = parts[-1]
            files[path] = {"path": path, "status": status, "additions": 0}

    if numstat and numstat.returncode == 0:
        for line in numstat.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            added, _deleted, path = parts[0], parts[1], parts[-1]
            if path not in files:
                continue
            try:
                files[path]["additions"] = int(added)
            except ValueError:
                files[path]["additions"] = 0

    return list(files.values())


def matches_target(path, patterns):
    for pattern in patterns:
        if pattern == "docs/**/*.md" and path.startswith("docs/") and path.endswith(".md"):
            return True
        if pattern == "deliverables/**/*.md" and path.startswith("deliverables/") and path.endswith(".md"):
            return True
        if fnmatch.fnmatch(path, pattern):
            return True
    return False


def prose_text(markdown):
    text = HTML_COMMENT_RE.sub(" ", markdown)
    text = FENCED_CODE_BLOCK_RE.sub(" ", text)
    text = URL_RE.sub(" ", text)
    text = INLINE_CODE_RE.sub(" ", text)
    prose_lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("|") and stripped.endswith("|"):
            continue
        prose_lines.append(line)
    return "\n".join(prose_lines)


def metric_for_file(path, changed, config, root):
    text = (root / path).read_text(encoding="utf-8")
    prose = prose_text(text)
    cjk_chars = len(CJK_RE.findall(prose))
    english_words = len(ENGLISH_WORD_RE.findall(prose))
    denominator = cjk_chars + english_words
    cjk_ratio = cjk_chars / denominator if denominator else 1.0
    missing_sections = [
        heading for heading in REQUIRED_SECTION_HEADINGS if heading not in text
    ]
    eligible = changed["status"].startswith(("A", "C")) or changed["additions"] >= config["min_changed_lines"]
    return {
        "path": path,
        "status": changed["status"],
        "additions": changed["additions"],
        "eligible_for_enforcement": eligible,
        "cjk_chars": cjk_chars,
        "english_words": english_words,
        "cjk_ratio": round(cjk_ratio, 4),
        "missing_required_sections": missing_sections,
    }


def requires_sections(path):
    return path.startswith("docs/") or path.startswith("deliverables/")


def violations_for_metric(metric, config):
    if not metric["eligible_for_enforcement"]:
        return []

    path = metric["path"]
    violations = []
    english_heavy = metric["english_words"] >= config["min_english_words"]

    if english_heavy and metric["cjk_chars"] == 0:
        violations.append(
            {
                "code": "doc_missing_chinese",
                "path": path,
                "message": f"{path} has no Chinese prose characters",
            }
        )
    elif english_heavy and (
        metric["cjk_chars"] < config["min_cjk_chars"]
        or metric["cjk_ratio"] < config["min_cjk_ratio"]
    ):
        violations.append(
            {
                "code": "doc_chinese_ratio_too_low",
                "path": path,
                "message": f"{path} Chinese readability ratio is too low",
            }
        )

    if config["require_sections"] and requires_sections(path):
        if "中文摘要" in metric["missing_required_sections"]:
            violations.append(
                {
                    "code": "doc_missing_chinese_summary",
                    "path": path,
                    "message": f"{path} is missing a 中文摘要 section",
                }
            )
        if "术语说明" in metric["missing_required_sections"]:
            violations.append(
                {
                    "code": "doc_missing_terminology_notes",
                    "path": path,
                    "message": f"{path} is missing a 术语说明 section",
                }
            )
    return violations


def result_payload(mode, skipped, scanned_files, metrics, violations, warnings, started_at):
    passed = mode != "enforce" or not violations
    return {
        "check_id": "D-12",
        "check_name": "PR Doc Chinese Readability",
        "passed": passed,
        "mode": mode,
        "skipped": skipped,
        "scanned_files": scanned_files,
        "metrics": metrics,
        "violations": violations,
        "warnings": warnings,
        "runtime_ms": int((time.time() - started_at) * 1000),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def write_summary(path, payload):
    if not path:
        return
    summary = Path(path)
    summary.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "## D-12 PR 文档中文可读性检查",
        "",
        f"- mode: `{payload['mode']}`",
        f"- passed: `{str(payload['passed']).lower()}`",
        f"- scanned files: `{len(payload['scanned_files'])}`",
        f"- violations: `{len(payload['violations'])}`",
        "",
    ]
    if payload["violations"]:
        lines.extend(["| File | Code | Message |", "| --- | --- | --- |"])
        for violation in payload["violations"]:
            lines.append(
                f"| `{violation.get('path', '')}` | `{violation.get('code', '')}` | {violation.get('message', '')} |"
            )
        lines.append("")
    elif payload["skipped"]:
        lines.append("No applicable Markdown files were scanned.")
    else:
        lines.append("No readability violations found.")
    summary.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv=None):
    started_at = time.time()
    parser = argparse.ArgumentParser(description="Check PR Markdown Chinese readability")
    parser.add_argument("--config", default=".sentinel/config.yaml")
    parser.add_argument("--results-dir", default=".sentinel/results")
    parser.add_argument("--mode", choices=("disabled", "audit", "enforce"))
    parser.add_argument("--summary-file")
    args = parser.parse_args(argv)

    root = repo_root()
    config = parse_doc_readability_config(args.config)
    if args.mode:
        config["mode"] = args.mode

    results_dir = Path(args.results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)
    result_file = results_dir / "d12-pr-doc-readability.json"
    summary_file = args.summary_file or os.environ.get("D12_STEP_SUMMARY_FILE", "")

    if config["mode"] == "disabled":
        payload = result_payload("disabled", True, [], [], [], [], started_at)
        result_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        write_summary(summary_file, payload)
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    allowlist_ref = config["allowlist_file"]
    allowlist_path = str((root / allowlist_ref).resolve()) if allowlist_ref else ""
    allowlist_entries, warnings = parse_allowlist_file(allowlist_path)

    metrics = []
    violations = []
    today = date.today()
    changes = changed_files(root)
    changed_paths = {changed["path"] for changed in changes}
    if allowlist_ref and allowlist_ref in changed_paths:
        for entry in allowlist_entries:
            path = entry.get("path", "")
            if path and path not in changed_paths and (root / path).is_file():
                changes.append(
                    {
                        "path": path,
                        "status": "M",
                        "additions": config["min_changed_lines"],
                    }
                )
                changed_paths.add(path)

    for changed in changes:
        path = changed["path"]
        full_path = root / path
        if not matches_target(path, config["target_patterns"]):
            continue
        if not full_path.exists() or not full_path.is_file():
            continue
        metric = metric_for_file(path, changed, config, root)
        metrics.append(metric)
        file_violations = violations_for_metric(metric, config)
        if not file_violations:
            continue
        allowed, allowlist_warning = is_allowlisted(path, allowlist_entries, today)
        if allowlist_warning:
            warnings.append(allowlist_warning)
        if allowed:
            continue
        violations.extend(file_violations)

    scanned_files = [metric["path"] for metric in metrics]
    payload = result_payload(
        config["mode"],
        not scanned_files,
        scanned_files,
        metrics,
        violations,
        warnings,
        started_at,
    )
    result_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    write_summary(summary_file, payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))

    if config["mode"] == "enforce" and violations:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
