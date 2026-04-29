import threading
import unittest
from unittest.mock import patch

from cmux_harness.engine import HarnessEngine, AUTO_SESSION_MAX_SECONDS


def make_engine():
    engine = HarnessEngine.__new__(HarnessEngine)
    engine._lock = threading.Lock()
    engine.ws_config = {}
    engine.workspace_enabled = {}
    engine.auto_policy_last_check = {}
    engine.auto_policy_last_action_fingerprint = {}
    engine.auto_policy_pending_human_fingerprint = {}
    engine.approval_log = []
    engine.approval_threshold = 3
    engine.session_ids = {}
    engine._save_config = lambda: None
    return engine


class TestAutoPolicy(unittest.TestCase):
    def test_low_confidence_submit_becomes_alert(self):
        engine = make_engine()

        result = engine._normalize_auto_policy_result({
            "action": "approve",
            "submit": "enter",
            "confidence": 0.6,
            "reason": "maybe",
        })

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
        self.assertEqual(mock_log.call_args.args[0]["promptType"], "haiku-auto-guard")

    def test_level_above_threshold_becomes_alert(self):
        engine = make_engine()

        result = engine._normalize_auto_policy_result({
            "action": "approve",
            "submit": "enter",
            "level": 4,
            "confidence": 0.95,
            "reason": "Needs judgment.",
        })

        self.assertEqual(result["action"], "alert")
        self.assertEqual(result["submit"], "none")
        self.assertEqual(result["level"], 4)

    def test_level_at_custom_threshold_can_approve(self):
        engine = make_engine()
        engine.approval_threshold = 4

        result = engine._normalize_auto_policy_result({
            "action": "approve",
            "submit": "enter",
            "level": 4,
            "confidence": 0.95,
            "reason": "Allowed by threshold.",
        })

        self.assertEqual(result["action"], "approve")
        self.assertEqual(result["submit"], "enter")
        self.assertEqual(result["level"], 4)

    def test_super_auto_bypasses_threshold_and_confidence(self):
        engine = make_engine()

        result = engine._normalize_auto_policy_result({
            "action": "approve",
            "submit": "enter",
            "level": 5,
            "confidence": 0.2,
            "reason": "Super auto should approve.",
        }, auto_mode="super")

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
    @patch("cmux_harness.engine.claude_cli.run_haiku")
    def test_haiku_approve_sends_enter(self, mock_haiku, mock_ready, mock_send):
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
        mock_haiku.return_value = {
            "action": "approve",
            "submit": "enter",
            "level": 2,
            "confidence": 0.95,
            "reason": "Low-risk read-only prompt.",
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, "Allow Read?\n(Y/n)", 200.0)

        mock_ready.assert_called_once_with(workspace_uuid=workspace_id, surface_id="surface:1")
        mock_send.assert_called_once_with(
            3,
            0,
            key="enter",
            workspace_uuid=workspace_id,
            surface_id="surface:1",
        )
        self.assertEqual(mock_log.call_args.args[0]["action"], "auto approve enter")
        self.assertEqual(mock_log.call_args.args[0]["severityLevel"], 2)

    @patch("cmux_harness.engine.cmux_api.cmux_send_to_workspace", return_value=True)
    @patch("cmux_harness.engine.cmux_api.ensure_workspace_terminal_ready", return_value=True)
    @patch("cmux_harness.engine.push_notifications.notify_auto_mode_human_alert")
    @patch("cmux_harness.engine.claude_cli.run_haiku")
    def test_super_auto_alert_defaults_to_enter(self, mock_haiku, mock_notify, mock_ready, mock_send):
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
        mock_haiku.return_value = {
            "action": "alert",
            "submit": "none",
            "level": 5,
            "confidence": 0.4,
            "reason": "Destructive command.",
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
    @patch("cmux_harness.engine.claude_cli.run_haiku")
    def test_repeated_human_alert_does_not_recheck_haiku(self, mock_haiku, mock_notify):
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
        mock_haiku.return_value = {
            "action": "alert",
            "submit": "none",
            "level": 5,
            "confidence": 0.98,
            "reason": "Destructive command.",
        }

        with patch.object(engine, "_append_log") as mock_log:
            engine._run_auto_policy_for_workspace(ws, screen, 200.0)
            engine._run_auto_policy_for_workspace(ws, screen, 200.0 + 2 * 60)

        mock_haiku.assert_called_once()
        mock_log.assert_called_once()
        mock_notify.assert_called_once()


if __name__ == "__main__":
    unittest.main()
