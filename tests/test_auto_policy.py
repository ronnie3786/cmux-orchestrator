import threading
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import auto_policy
from cmux_harness import storage
from cmux_harness.engine import HarnessEngine, AUTO_SESSION_MAX_SECONDS


def make_engine():
    engine = HarnessEngine.__new__(HarnessEngine)
    engine._lock = threading.Lock()
    engine.ws_config = {}
    engine.workspace_enabled = {}
    engine.auto_policy_last_check = {}
    engine.auto_policy_last_checked_fingerprint = {}
    engine.auto_policy_last_action_fingerprint = {}
    engine.auto_policy_pending_human_fingerprint = {}
    engine.approval_log = []
    engine.approval_threshold = 3
    engine.session_ids = {}
    engine._save_config = lambda: None
    return engine


class TestAutoPolicy(unittest.TestCase):
    def test_low_confidence_submit_becomes_alert(self):
        result = auto_policy.normalize_policy_result({
            "ok": True,
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "approve",
                "submit": "enter",
                "level": 2,
                "confidence": 0.6,
                "reason": "maybe",
            },
        }, auto_mode="auto", threshold=3)

        self.assertEqual(result["action"], "alert")
        self.assertEqual(result["submit"], "none")

    def test_guard_disables_auto_after_eight_hours(self):
        engine = make_engine()
        workspace_id = "ws-1"
        engine.ws_config[workspace_id] = {
            "autoEnabled": True,
            "autoEnabledAt": 100.0,
        }
        ws = {"index": 7, "uuid": workspace_id, "name": "Workspace"}

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(
                ws,
                "Allow Bash command?\n(Y/n)",
                100.0 + AUTO_SESSION_MAX_SECONDS + 1,
            )

        self.assertFalse(engine.ws_config[workspace_id]["autoEnabled"])
        self.assertNotIn("autoEnabledAt", engine.ws_config[workspace_id])
        self.assertFalse(engine.workspace_enabled[7])
        mock_log.assert_called_once()
        self.assertEqual(mock_log.call_args.args[0]["promptType"], "auto-policy-guard")

    def test_level_above_threshold_becomes_alert(self):
        result = auto_policy.normalize_policy_result({
            "ok": True,
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "approve",
                "submit": "enter",
                "level": 4,
                "confidence": 0.95,
                "reason": "Needs judgment.",
            },
        }, auto_mode="auto", threshold=3)

        self.assertEqual(result["action"], "alert")
        self.assertEqual(result["submit"], "none")
        self.assertEqual(result["level"], 4)

    def test_level_at_custom_threshold_can_approve(self):
        result = auto_policy.normalize_policy_result({
            "ok": True,
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "approve",
                "submit": "enter",
                "level": 4,
                "confidence": 0.95,
                "reason": "Allowed by threshold.",
            },
        }, auto_mode="auto", threshold=4)

        self.assertEqual(result["action"], "approve")
        self.assertEqual(result["submit"], "enter")
        self.assertEqual(result["level"], 4)

    def test_super_auto_bypasses_threshold_and_confidence(self):
        result = auto_policy.normalize_policy_result({
            "ok": True,
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "approve",
                "submit": "enter",
                "level": 5,
                "confidence": 0.2,
                "reason": "Super auto should approve.",
            },
        }, auto_mode="super", threshold=3)

        self.assertEqual(result["action"], "approve")
        self.assertEqual(result["submit"], "enter")
        self.assertEqual(result["level"], 5)

    def test_starred_workspace_state_persists_by_uuid(self):
        engine = make_engine()
        engine.workspaces = [{"index": 7, "uuid": "ws-1", "name": "Workspace"}]

        ok = engine.set_workspace_starred(7, True)

        self.assertTrue(ok)
        self.assertTrue(engine.ws_config["ws-1"]["starred"])

    def test_super_auto_workspace_state_persists_by_uuid(self):
        engine = make_engine()
        engine.workspaces = [{"index": 7, "uuid": "ws-1", "name": "Workspace"}]

        engine.set_workspace_enabled(7, True, auto_mode="super")

        self.assertTrue(engine.ws_config["ws-1"]["autoEnabled"])
        self.assertEqual(engine.ws_config["ws-1"]["autoMode"], "super")

    @patch("cmux_harness.engine.cmux_api.cmux_send_to_workspace", return_value=True)
    @patch("cmux_harness.engine.cmux_api.ensure_workspace_terminal_ready", return_value=True)
    @patch("cmux_harness.engine.auto_policy.record_policy_usage")
    @patch("cmux_harness.engine.auto_policy.run_auto_policy")
    def test_auto_policy_approve_sends_enter(self, mock_policy, mock_record_usage, mock_ready, mock_send):
        engine = make_engine()
        workspace_id = "ws-1"
        engine.ws_config[workspace_id] = {
            "autoEnabled": True,
            "autoEnabledAt": 100.0,
        }
        ws = {
            "index": 7,
            "_real_index": 3,
            "_surface_id": "surface:1",
            "uuid": workspace_id,
            "name": "Workspace",
            "_cwd": "/repo",
        }
        mock_policy.return_value = {
            "ok": True,
            "provider": "fireworks",
            "model": "accounts/fireworks/models/minimax-m2p7",
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "approve",
                "submit": "enter",
                "level": 2,
                "confidence": 0.95,
                "reason": "Low-risk read-only prompt.",
            },
            "usage": {"inputTokens": 100, "outputTokens": 20, "totalTokens": 120},
            "latencyMs": 10,
            "promptChars": 500,
        }
        mock_record_usage.return_value = {
            "inputTokens": 100,
            "outputTokens": 20,
            "estimatedCostUSD": 0.000054,
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, "Allow Read?\n(Y/n)", 200.0)

        mock_policy.assert_called_once()
        mock_record_usage.assert_called_once()
        mock_ready.assert_called_once_with(workspace_uuid=workspace_id, surface_id="surface:1")
        mock_send.assert_called_once_with(
            3,
            0,
            key="enter",
            workspace_uuid=workspace_id,
            surface_id="surface:1",
        )
        self.assertEqual(mock_log.call_args.args[0]["action"], "auto approve enter")
        self.assertEqual(mock_log.call_args.args[0]["promptType"], "fireworks-auto-policy")
        self.assertEqual(mock_log.call_args.args[0]["severityLevel"], 2)
        self.assertEqual(mock_log.call_args.args[0]["inputTokens"], 100)
        self.assertEqual(mock_log.call_args.args[0]["outputTokens"], 20)

    @patch("cmux_harness.engine.cmux_api.cmux_send_to_workspace", return_value=True)
    @patch("cmux_harness.engine.cmux_api.ensure_workspace_terminal_ready", return_value=True)
    @patch("cmux_harness.engine.push_notifications.notify_auto_mode_human_alert")
    @patch("cmux_harness.engine.auto_policy.record_policy_usage")
    @patch("cmux_harness.engine.auto_policy.run_auto_policy")
    def test_super_auto_alert_with_submit_approves(self, mock_policy, mock_record_usage, mock_notify, mock_ready, mock_send):
        engine = make_engine()
        workspace_id = "ws-1"
        engine.ws_config[workspace_id] = {
            "autoEnabled": True,
            "autoMode": "super",
            "autoEnabledAt": 100.0,
        }
        ws = {
            "index": 7,
            "_real_index": 3,
            "_surface_id": "surface:1",
            "uuid": workspace_id,
            "name": "Workspace",
            "_cwd": "/repo",
        }
        mock_policy.return_value = {
            "ok": True,
            "provider": "fireworks",
            "model": "accounts/fireworks/models/minimax-m2p7",
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "alert",
                "submit": "enter",
                "level": 5,
                "confidence": 0.4,
                "reason": "Destructive command.",
            },
            "usage": {"inputTokens": 100, "outputTokens": 20, "totalTokens": 120},
            "latencyMs": 10,
            "promptChars": 500,
        }
        mock_record_usage.return_value = {
            "inputTokens": 100,
            "outputTokens": 20,
            "estimatedCostUSD": 0.000054,
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, "Allow Bash command?\n(Y/n)", 200.0)

        mock_notify.assert_not_called()
        mock_ready.assert_called_once_with(workspace_uuid=workspace_id, surface_id="surface:1")
        mock_send.assert_called_once_with(
            3,
            0,
            key="enter",
            workspace_uuid=workspace_id,
            surface_id="surface:1",
        )
        self.assertEqual(mock_log.call_args.args[0]["action"], "auto approve enter")
        self.assertEqual(mock_log.call_args.args[0]["autoMode"], "super")

    @patch("cmux_harness.engine.push_notifications.notify_auto_mode_human_alert")
    @patch("cmux_harness.engine.auto_policy.record_policy_usage")
    @patch("cmux_harness.engine.auto_policy.run_auto_policy")
    def test_repeated_human_alert_does_not_recheck_policy(self, mock_policy, mock_record_usage, mock_notify):
        engine = make_engine()
        workspace_id = "ws-1"
        engine.ws_config[workspace_id] = {
            "autoEnabled": True,
            "autoEnabledAt": 100.0,
        }
        ws = {
            "index": 7,
            "_real_index": 3,
            "_surface_id": "surface:1",
            "uuid": workspace_id,
            "name": "Workspace",
            "_cwd": "/repo",
        }
        screen = "Allow Bash command?\nrm -rf build\n(Y/n)"
        mock_policy.return_value = {
            "ok": True,
            "provider": "fireworks",
            "model": "accounts/fireworks/models/minimax-m2p7",
            "policy": {
                "approvalNeeded": True,
                "terminalState": "approval_prompt",
                "action": "alert",
                "submit": "none",
                "level": 5,
                "confidence": 0.98,
                "reason": "Destructive command.",
            },
            "usage": {"inputTokens": 100, "outputTokens": 20, "totalTokens": 120},
            "latencyMs": 10,
            "promptChars": 500,
        }
        mock_record_usage.return_value = {
            "inputTokens": 100,
            "outputTokens": 20,
            "estimatedCostUSD": 0.000054,
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, screen, 200.0)
            engine._run_auto_policy_for_workspace(ws, screen, 200.0 + 2 * 60)

        mock_policy.assert_called_once()
        mock_log.assert_called_once()
        mock_notify.assert_called_once()

    @patch("cmux_harness.engine.auto_policy.record_policy_usage")
    @patch("cmux_harness.engine.auto_policy.run_auto_policy")
    def test_unchanged_screen_tail_is_not_rechecked_after_ignore(self, mock_policy, mock_record_usage):
        engine = make_engine()
        workspace_id = "ws-1"
        engine.ws_config[workspace_id] = {
            "autoEnabled": True,
            "autoEnabledAt": 100.0,
        }
        ws = {
            "index": 7,
            "_real_index": 3,
            "_surface_id": "surface:1",
            "uuid": workspace_id,
            "name": "Workspace",
            "_cwd": "/repo",
        }
        screen = "ronnie@dev repo %"
        mock_policy.return_value = {
            "ok": True,
            "provider": "fireworks",
            "model": "accounts/fireworks/models/minimax-m2p7",
            "policy": {
                "approvalNeeded": False,
                "terminalState": "idle_prompt",
                "action": "ignore",
                "submit": "none",
                "level": None,
                "confidence": 0.99,
                "reason": "No approval prompt.",
            },
            "usage": {"inputTokens": 90, "outputTokens": 15, "totalTokens": 105},
            "latencyMs": 10,
            "promptChars": 400,
        }
        mock_record_usage.return_value = {
            "inputTokens": 90,
            "outputTokens": 15,
            "estimatedCostUSD": 0.000045,
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, screen, 200.0)
            engine._run_auto_policy_for_workspace(ws, screen, 200.0 + 2 * 60)

        mock_policy.assert_called_once()
        mock_record_usage.assert_called_once()
        mock_log.assert_not_called()


class TestAutoPolicyCostLog(unittest.TestCase):
    def test_estimate_cost_uses_configured_rates(self):
        self.assertEqual(auto_policy.estimate_cost(1_000_000, 1_000_000), 1.5)

    def test_record_policy_usage_tracks_tokens_without_terminal_text(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "auto-policy-cost-log.jsonl"
            with patch.object(storage, "AUTO_POLICY_COST_LOG", log_path):
                stored = auto_policy.record_policy_usage({
                    "workspace": 7,
                    "workspaceName": "Feature",
                    "workspaceUuid": "ws-1",
                    "surfaceId": "surface:1",
                    "autoMode": "auto",
                    "screenFingerprint": "abc123",
                    "approvalThreshold": 3,
                    "terminalState": "approval_prompt",
                    "approvalNeeded": True,
                    "action": "approve",
                    "submit": "enter",
                    "severityLevel": 2,
                    "confidence": 0.95,
                    "reason": "Safe prompt.",
                    "usage": {"inputTokens": 1000, "outputTokens": 200, "totalTokens": 1200},
                    "latencyMs": 42,
                    "promptChars": 500,
                })
                dashboard = auto_policy.cost_dashboard(limit=20)

        self.assertEqual(stored["inputTokens"], 1000)
        self.assertEqual(stored["outputTokens"], 200)
        self.assertAlmostEqual(stored["estimatedCostUSD"], 0.00054)
        self.assertEqual(dashboard["totals"]["calls"], 1)
        self.assertEqual(dashboard["totals"]["approvals"], 1)
        self.assertNotIn("screen", dashboard["entries"][0])


if __name__ == "__main__":
    unittest.main()
