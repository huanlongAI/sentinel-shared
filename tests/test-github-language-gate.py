#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-github-language-gate.py"


def run_gate(event, enforcement_mode="enforce", github_output_path=None):
    with tempfile.TemporaryDirectory() as tmp:
        event_path = Path(tmp) / "event.json"
        event_path.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")
        cmd = [
            sys.executable,
            str(SCRIPT),
            "--event-path",
            str(event_path),
            "--enforcement-mode",
            enforcement_mode,
        ]
        if github_output_path:
            cmd.extend(["--github-output", str(github_output_path)])
        return subprocess.run(cmd, capture_output=True, text=True)


class GitHubLanguageGateTests(unittest.TestCase):
    def test_rejects_internal_pure_english_issue_title_and_body(self):
        result = run_gate(
            {
                "action": "opened",
                "issue": {
                    "title": "[ledger test] Feishu delivery ledger summary",
                    "body": "Purpose: verify Feishu delivery ledger summary.",
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/179",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["actor_scope"], "internal")
        self.assertIn("title_missing_chinese", payload["errors"])
        self.assertIn("body_missing_chinese", payload["errors"])

    def test_accepts_chinese_issue_with_english_terms(self):
        result = run_gate(
            {
                "action": "opened",
                "issue": {
                    "title": "[通知台账测试] Feishu delivery ledger summary",
                    "body": "目的：验证 Feishu delivery ledger summary。",
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/180",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "passed")

    def test_rejects_english_body_with_incidental_chinese_terms(self):
        result = run_gate(
            {
                "action": "opened",
                "issue": {
                    "title": "[通知台账测试] Feishu delivery ledger summary",
                    "body": (
                        "Purpose: verify Feishu delivery ledger summary.\n\n"
                        "Expected:\n"
                        "- Issue opened goes to AI native工程通知.\n"
                        "- Assigned goes DM-only to tongzhenghui.\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/181",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn("body_chinese_ratio_too_low", payload["errors"])

    def test_external_contributor_violation_warns_without_failing(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": "Status: ready. Next: close after verification.",
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/179#issuecomment-1",
                    "author_association": "FIRST_TIME_CONTRIBUTOR",
                },
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "warn")
        self.assertEqual(payload["actor_scope"], "external")
        self.assertIn("comment_missing_chinese", payload["warnings"])
        self.assertEqual(payload["errors"], [])

    def test_audit_mode_reports_internal_violation_without_failing(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": "Status: blocked pending runtime owner evidence.",
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/164#issuecomment-1",
                    "author_association": "MEMBER",
                },
            },
            enforcement_mode="audit",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "failed")
        self.assertIn("comment_missing_chinese", payload["errors"])
        self.assertTrue(payload["audit_mode"])

    def test_allows_owner_confirmation_yaml_without_chinese(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "owner_confirmation_response_v1:\n"
                        "  dispatch_id: FE-OC-001\n"
                        "  decision: confirmed\n"
                        "  blockers: []\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/101#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "passed")
        self.assertTrue(payload["structured_yaml_allowed"])

    def test_writes_github_output_for_failed_comment(self):
        with tempfile.TemporaryDirectory() as tmp:
            github_output_path = Path(tmp) / "github-output.txt"
            result = run_gate(
                {
                    "action": "created",
                    "issue": {
                        "number": 164,
                        "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/164",
                    },
                    "comment": {
                        "body": "Status: blocked pending runtime owner evidence.",
                        "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/164#issuecomment-1",
                        "author_association": "MEMBER",
                    },
                },
                github_output_path=github_output_path,
            )

            self.assertEqual(result.returncode, 1)
            github_output = github_output_path.read_text(encoding="utf-8")
            self.assertIn("status=failed", github_output)
            self.assertIn("target_issue_number=164", github_output)
            self.assertIn("errors=comment_missing_chinese", github_output)

    def test_accepts_valid_ai_output_contract_comment(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "<!-- ai-output:v1 -->\n"
                        "【类型】status_update\n"
                        "【结论】DS-1A sandbox pilot evidence accepted，未声明 production ready。\n"
                        "【依据】PR #110；CI sentinel success；integration test evidence 已记录。\n"
                        "【当前状态】accepted\n"
                        "【下一步唯一动作】Package Owner 更新 Task Snapshot。\n"
                        "【需要人处理】Package Owner\n"
                        "【不确定项】无\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/200#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "passed")

    def test_rejects_ai_output_missing_required_field(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "<!-- ai-output:v1 -->\n"
                        "【类型】status_update\n"
                        "【结论】已完成。\n"
                        "【依据】PR #110\n"
                        "【当前状态】accepted\n"
                        "【下一步唯一动作】关闭。\n"
                        "【需要人处理】Package Owner\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/200#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn("ai_output_missing_不确定项", payload["errors"])

    def test_rejects_ai_output_invalid_type(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "<!-- ai-output:v1 -->\n"
                        "【类型】普通同步\n"
                        "【结论】继续推进整体治理。\n"
                        "【依据】PR #110\n"
                        "【当前状态】doing\n"
                        "【下一步唯一动作】继续推进。\n"
                        "【需要人处理】无\n"
                        "【不确定项】无\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/200#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn("ai_output_invalid_type", payload["errors"])

    def test_rejects_needs_context_without_gap_report(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "<!-- ai-output:v1 -->\n"
                        "【类型】status_update\n"
                        "【结论】NEEDS_CONTEXT：缺少 Task Snapshot。\n"
                        "【依据】未找到 task-snapshot:v1\n"
                        "【当前状态】blocked\n"
                        "【下一步唯一动作】补 Task Snapshot。\n"
                        "【需要人处理】Package Owner\n"
                        "【不确定项】当前 DRI\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/200#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn("ai_output_needs_context_requires_gap_report", payload["errors"])

    def test_rejects_done_claim_without_evidence(self):
        result = run_gate(
            {
                "action": "created",
                "comment": {
                    "body": (
                        "<!-- ai-output:v1 -->\n"
                        "【类型】status_update\n"
                        "【结论】已完成，可以关闭。\n"
                        "【依据】无\n"
                        "【当前状态】done\n"
                        "【下一步唯一动作】关闭 Issue。\n"
                        "【需要人处理】无\n"
                        "【不确定项】无\n"
                    ),
                    "html_url": "https://github.com/huanlongAI/hl-dispatch/issues/200#issuecomment-1",
                    "author_association": "MEMBER",
                },
            }
        )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertIn("ai_output_evidence_required", payload["errors"])


if __name__ == "__main__":
    unittest.main()
