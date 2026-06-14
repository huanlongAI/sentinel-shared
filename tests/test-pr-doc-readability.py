#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-pr-doc-readability.py"


def run(command, cwd, check=True):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise AssertionError(
            f"command failed: {' '.join(command)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def init_repo():
    tmp = tempfile.TemporaryDirectory()
    repo = Path(tmp.name) / "repo"
    repo.mkdir()
    run(["git", "init", "-q"], repo)
    run(["git", "config", "user.email", "sentinel-test@example.invalid"], repo)
    run(["git", "config", "user.name", "Sentinel Test"], repo)
    (repo / ".sentinel").mkdir()
    (repo / ".sentinel" / "config.yaml").write_text(
        textwrap.dedent(
            """\
            sentinel_version: "1.0"
            doc_readability:
              mode: enforce
            """
        ),
        encoding="utf-8",
    )
    (repo / "README.md").write_text("# 基线\n", encoding="utf-8")
    run(["git", "add", "."], repo)
    run(["git", "commit", "-q", "-m", "base"], repo)
    return tmp, repo


def run_gate(repo, mode=None):
    results_dir = repo / ".sentinel" / "results"
    command = [
        sys.executable,
        str(SCRIPT),
        "--config",
        ".sentinel/config.yaml",
        "--results-dir",
        str(results_dir),
    ]
    if mode:
        command.extend(["--mode", mode])
    result = subprocess.run(command, cwd=repo, capture_output=True, text=True)
    result_file = results_dir / "d12-pr-doc-readability.json"
    payload = json.loads(result_file.read_text(encoding="utf-8")) if result_file.exists() else None
    return result, payload


class PrDocReadabilityTests(unittest.TestCase):
    def test_skips_when_no_target_markdown_changed(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        (repo / "scripts").mkdir()
        (repo / "scripts" / "tool.py").write_text("print('ok')\n", encoding="utf-8")
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "change code only"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["passed"])
        self.assertTrue(payload["skipped"])
        self.assertEqual(payload["scanned_files"], [])

    def test_rejects_added_english_governance_doc_in_enforce_mode(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        doc = repo / "docs" / "delivery-recovery" / "HL_PROGRESS_GOVERNANCE_LOOP_v0.1.md"
        doc.parent.mkdir(parents=True)
        doc.write_text(
            "# HL Progress Governance Loop\n\n"
            + "\n".join(
                [
                    "This governance contract defines status, evidence, owner, blocker, and gate semantics for engineering progress.",
                    "GitHub remains the source of truth while dashboards and reports are projections for scanning.",
                    "The document intentionally describes authority boundaries, acceptance evidence, and decision ownership.",
                ]
                * 20
            ),
            encoding="utf-8",
        )
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "add english governance doc"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(payload["passed"])
        self.assertFalse(payload["skipped"])
        self.assertEqual(payload["mode"], "enforce")
        self.assertIn(str(doc.relative_to(repo)), payload["scanned_files"])
        codes = {v["code"] for v in payload["violations"]}
        self.assertIn("doc_missing_chinese", codes)
        self.assertIn("doc_missing_chinese_summary", codes)
        self.assertIn("doc_missing_terminology_notes", codes)

    def test_audit_mode_reports_violations_without_failing(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        doc = repo / "docs" / "delivery-recovery" / "ENGLISH_ONLY.md"
        doc.parent.mkdir(parents=True)
        doc.write_text("This delivery recovery governance note is English only.\n" * 80, encoding="utf-8")
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "add audit doc"], repo)

        result, payload = run_gate(repo, mode="audit")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["passed"])
        self.assertEqual(payload["mode"], "audit")
        self.assertGreater(len(payload["violations"]), 0)

    def test_accepts_chinese_summary_and_terminology_notes(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        doc = repo / "deliverables" / "tasks" / "HL-PROGRESS-TASKBOOK.md"
        doc.parent.mkdir(parents=True)
        doc.write_text(
            textwrap.dedent(
                """\
                # HL Progress Taskbook

                ## 中文摘要

                本文定义工程进度治理任务书，说明 GitHub SSOT、证据、负责人、阻塞项和门禁状态。
                文档允许保留英文术语，但必须提供中文解释，方便 Founder、PM 和工程成员阅读。

                ## 术语说明

                - GitHub SSOT：GitHub 作为事实源，不以飞书或看板作为最终证据。
                - gate：门禁，用于阻止缺少证据或缺少上下文的变更。

                ## Details

                The exporter may use JSON, Markdown, and dashboard projections for scanning.
                """
            )
            * 12,
            encoding="utf-8",
        )
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "add readable taskbook"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["passed"])
        self.assertEqual(payload["violations"], [])
        self.assertEqual(payload["metrics"][0]["missing_required_sections"], [])

    def test_ignores_code_blocks_urls_and_table_pipes_for_language_metrics(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        doc = repo / "docs" / "delivery-recovery" / "CODE_HEAVY.md"
        doc.parent.mkdir(parents=True)
        doc.write_text(
            textwrap.dedent(
                """\
                # Code Heavy Doc

                ## 中文摘要

                这个文档用于记录命令样例，正文中文足够，代码块里的英文命令不应降低可读性判断。

                ## 术语说明

                - exporter：导出器，用于读取 GitHub 证据并生成投影。

                ```yaml
                schema: hl-progress-work-item:v0.1
                source:
                  system: github
                  repo: owner/repo
                  pr_urls:
                    - https://github.com/huanlongAI/hl-dispatch/pull/236
                ```

                | field | meaning |
                | --- | --- |
                | owner | owner handle |
                """
            ),
            encoding="utf-8",
        )
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "add code heavy doc"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["passed"])
        metric = payload["metrics"][0]
        self.assertLess(metric["english_words"], 20)
        self.assertEqual(payload["violations"], [])

    def test_unexpired_allowlist_suppresses_violation_and_expired_allowlist_fails(self):
        tmp, repo = init_repo()
        self.addCleanup(tmp.cleanup)
        doc = repo / "docs" / "delivery-recovery" / "TEMP_ENGLISH_DRAFT.md"
        doc.parent.mkdir(parents=True)
        doc.write_text("Temporary English governance draft.\n" * 80, encoding="utf-8")
        allowlist = repo / "docs" / "readability-allowlist.yml"
        allowlist.write_text(
            textwrap.dedent(
                """\
                allowlist:
                  - path: docs/delivery-recovery/TEMP_ENGLISH_DRAFT.md
                    reason: temporary imported draft before Chinese rewrite
                    approval_ref: https://github.com/huanlongAI/hl-dispatch/issues/236
                    expires_on: 2999-01-01
                """
            ),
            encoding="utf-8",
        )
        with (repo / ".sentinel" / "config.yaml").open("a", encoding="utf-8") as config:
            config.write("  allowlist_file: docs/readability-allowlist.yml\n")
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "add allowlisted draft"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["passed"])
        self.assertEqual(payload["violations"], [])
        self.assertEqual(payload["warnings"][0]["code"], "doc_readability_allowlisted")

        allowlist.write_text(
            allowlist.read_text(encoding="utf-8").replace("2999-01-01", "2000-01-01"),
            encoding="utf-8",
        )
        run(["git", "add", "."], repo)
        run(["git", "commit", "-q", "-m", "expire allowlist"], repo)

        result, payload = run_gate(repo)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(payload["passed"])
        codes = {v["code"] for v in payload["violations"]}
        self.assertIn("doc_missing_chinese", codes)


if __name__ == "__main__":
    unittest.main()
