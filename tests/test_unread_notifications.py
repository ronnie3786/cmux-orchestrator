import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock, patch

from herdr_harness.alerts import AlertStore
from herdr_harness.push_notifications import APNsManager
from herdr_harness.unread_notifications import UnreadNotificationManager
from tests.test_herdr_service import snapshot_with_status


class UnreadNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store_path = Path(self.temp.name) / "alerts.json"
        self.alerts = AlertStore(store_path=self.store_path)
        self.push = APNsManager(environ={}, store_path=Path(self.temp.name) / "devices.json")
        self.push.register("ab" * 32, bundle_id="com.example.app", environment="sandbox", machine_id="work-mac")
        self.now = 1_800_000_000.0
        self.manager = UnreadNotificationManager(self.alerts, self.push, clock=lambda: self.now)
        self.alerts.observe_snapshot(snapshot_with_status("working"))
        with patch("herdr_harness.alerts.utc_now", return_value=datetime.fromtimestamp(self.now, timezone.utc).isoformat()):
            self.alerts.observe_snapshot(snapshot_with_status("done"))

    def test_grace_period_then_single_delivery_survives_restart(self):
        with patch.object(self.push, "_auth_token", return_value=("jwt", None)), patch.object(self.push, "_send", return_value=(True, "")) as send:
            self.now += 59.9
            self.manager.process_due()
            send.assert_not_called()
            self.now += 0.1
            self.manager.process_due()
            self.assertEqual(send.call_count, 1)
            self.assertEqual(send.call_args.args[1]["machine_id"], "work-mac")
            restarted = UnreadNotificationManager(AlertStore(store_path=self.store_path), self.push, clock=lambda: self.now + 1000)
            restarted.process_due()
            self.assertEqual(send.call_count, 1)
        self.assertNotIn("ab" * 32, self.store_path.read_text())

    def test_read_or_resumed_session_cancels_before_deadline(self):
        self.alerts.mark_read_for_pane("w1:p1")
        self.now += 61
        with patch.object(self.push, "notify_alert") as send:
            self.manager.process_due()
            send.assert_not_called()
        self.alerts.observe_snapshot(snapshot_with_status("working"))
        self.alerts.observe_snapshot(snapshot_with_status("blocked"))
        self.alerts.observe_snapshot(snapshot_with_status("working"))
        self.now += 1000
        with patch.object(self.push, "notify_alert") as send:
            self.manager.process_due()
            send.assert_not_called()

    def test_partial_failure_retries_only_failed_device_after_backoff(self):
        self.push.register("cd" * 32, bundle_id="com.example.app", environment="sandbox")
        self.now += 61
        with patch.object(self.push, "_auth_token", return_value=("jwt", None)), patch.object(self.push, "_send", side_effect=[(True, ""), (False, "offline"), (True, "")]) as send:
            self.manager.process_due()
            self.assertEqual(send.call_count, 2)
            restarted = UnreadNotificationManager(AlertStore(store_path=self.store_path), self.push, clock=lambda: self.now)
            restarted.process_due()
            self.assertEqual(send.call_count, 2)
            self.now += 15
            restarted.process_due()
            self.assertEqual(send.call_count, 3)
            self.assertEqual(send.call_args.args[0]["token"], "cd" * 32)

    def test_read_while_signing_cancels_delivery(self):
        self.now += 61
        def authorize():
            self.alerts.mark_read_for_pane("w1:p1")
            return "jwt", None
        with patch.object(self.push, "_auth_token", side_effect=authorize), patch.object(self.push, "_send") as send:
            self.manager.process_due()
            send.assert_not_called()

    def test_provider_exception_retries_without_losing_pending_alert(self):
        self.now += 61
        with patch.object(self.push, "notify_alert", side_effect=RuntimeError("network")) as send:
            self.manager.process_due()
            self.manager.process_due()
            self.assertEqual(send.call_count, 1)
            self.now += 15
            self.manager.process_due()
            self.assertEqual(send.call_count, 2)

    def test_newer_transition_while_signing_cancels_stale_delivery(self):
        self.now += 61
        def authorize():
            self.alerts.observe_snapshot(snapshot_with_status("blocked"))
            return "jwt", None
        with patch.object(self.push, "_auth_token", side_effect=authorize), patch.object(self.push, "_send") as send:
            self.manager.process_due()
            send.assert_not_called()

    def test_retry_failures_do_not_repeat_local_fallback_notifications(self):
        callback = Mock()
        self.manager.callback = callback
        self.now += 61
        with patch.object(self.push, "notify_alert", side_effect=RuntimeError("network")):
            self.manager.process_due()
            self.now += 15
            self.manager.process_due()
        self.assertEqual(callback.call_count, 1)
