import base64
import copy
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from herdr_harness import attachments
from herdr_harness.alerts import AlertStore
from herdr_harness.client import HerdrClientError
from herdr_harness.service import HerdrService
from herdr_harness.terminal import TerminalObserverError


def snapshot_with_status(status="working"):
    return {
        "version": "0.8.0",
        "protocol": 19,
        "future_session_field": {"kept": True},
        "focused_workspace_id": "w1",
        "focused_tab_id": "w1:t1",
        "focused_pane_id": "w1:p1",
        "workspaces": [
            {
                "workspace_id": "w1",
                "number": 1,
                "label": "Feature Lab",
                "focused": True,
                "pane_count": 1,
                "tab_count": 1,
                "active_tab_id": "w1:t1",
                "agent_status": status,
                "future_workspace_field": "preserved",
            }
        ],
        "tabs": [
            {
                "tab_id": "w1:t1",
                "workspace_id": "w1",
                "number": 1,
                "label": "Build",
                "focused": True,
                "pane_count": 1,
                "agent_status": status,
                "future_tab_field": 7,
            }
        ],
        "panes": [
            {
                "pane_id": "w1:p1",
                "terminal_id": "term_1",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "focused": True,
                "agent_status": status,
                "revision": 10,
                "title": "Implement settings",
                "future_pane_field": [1, 2],
            }
        ],
        "agents": [
            {
                "pane_id": "w1:p1",
                "terminal_id": "term_1",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "focused": True,
                "agent_status": status,
                "revision": 10,
                "name": "builder",
                "future_agent_field": {"yes": 1},
            }
        ],
        "layouts": [
            {
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "zoomed": False,
                "future_layout_field": "kept",
            }
        ],
    }


class FakeClient:
    def __init__(self, snapshots):
        self.snapshots = [copy.deepcopy(item) for item in snapshots]
        self.last = copy.deepcopy(self.snapshots[-1])
        self.socket_path = "/private/tmp/fake-herdr.sock"
        self.session = "fixtures"
        self.requests = []
        self.fail = False

    def snapshot(self):
        if self.fail:
            raise HerdrClientError("offline", code="herdr_unavailable")
        if self.snapshots:
            self.last = self.snapshots.pop(0)
        return copy.deepcopy(self.last)

    def request(self, method, params):
        self.requests.append((method, copy.deepcopy(params)))
        return {"type": "ok", "future_result": True}

    def subscribe_forever(self, *_args, **_kwargs):
        return None


class FakePush:
    def __init__(self):
        self.alerts = []

    def notify_alert_async(self, alert, *, unread_count, callback=None):
        self.alerts.append((copy.deepcopy(alert), unread_count))
        return True

    def configuration(self):
        return {"configured": False, "deviceCount": 0}

    def register(self, device_token, *, bundle_id, environment):
        return {"ok": True, "registered": True}

    def unregister(self, device_token):
        return {"ok": True, "unregistered": True}


class HerdrServiceTests(unittest.TestCase):
    def test_snapshot_is_raw_and_workspace_composite_preserves_unknown_fields(self):
        raw = snapshot_with_status()
        service = HerdrService(FakeClient([raw]), environ={})

        service.refresh_snapshot()
        snapshot_response = service.snapshot_response()
        workspace_response = service.workspaces_response()

        self.assertEqual(snapshot_response["snapshot"], raw)
        self.assertTrue(snapshot_response["snapshot"]["future_session_field"]["kept"])
        workspace = workspace_response["workspaces"][0]
        self.assertEqual(workspace["future_workspace_field"], "preserved")
        self.assertEqual(workspace["tabs"][0]["future_tab_field"], 7)
        self.assertEqual(workspace["panes"][0]["future_pane_field"], [1, 2])
        self.assertEqual(workspace["agents"][0]["future_agent_field"], {"yes": 1})
        self.assertEqual(workspace["layouts"][0]["future_layout_field"], "kept")

    def test_alerts_emit_once_per_real_blocked_or_done_transition(self):
        client = FakeClient(
            [
                snapshot_with_status("working"),
                snapshot_with_status("blocked"),
                snapshot_with_status("blocked"),
                snapshot_with_status("working"),
                snapshot_with_status("done"),
            ]
        )
        service = HerdrService(client, environ={})

        for _ in range(5):
            service.refresh_snapshot()

        alerts = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"]
        self.assertEqual([item["status"] for item in reversed(alerts)], ["blocked", "done"])
        self.assertEqual(alerts[0]["agentName"], "builder")
        self.assertEqual(alerts[0]["action"], {"type": "open_pane", "paneId": "w1:p1"})

    def test_event_then_snapshot_deduplicates_same_transition(self):
        client = FakeClient([snapshot_with_status("working"), snapshot_with_status("blocked")])
        service = HerdrService(client, environ={})
        service.refresh_snapshot()

        service._handle_event(
            {
                "event": "pane.agent_status_changed",
                "data": {
                    "pane_id": "w1:p1",
                    "workspace_id": "w1",
                    "agent_status": "blocked",
                    "display_agent": "Codex",
                },
            }
        )
        service.refresh_snapshot()

        alerts = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"]
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["status"], "blocked")

    def test_cached_snapshot_survives_disconnect_and_health_marks_it_stale(self):
        client = FakeClient([snapshot_with_status()])
        service = HerdrService(client, environ={})
        service.refresh_snapshot()
        client.fail = True

        with self.assertRaises(HerdrClientError):
            service.refresh_snapshot()

        self.assertEqual(service.snapshot_response()["snapshot"]["version"], "0.8.0")
        health = service.health_response()
        self.assertTrue(health["cache"]["available"])
        self.assertTrue(health["cache"]["stale"])
        self.assertFalse(health["herdr"]["connected"])

    def test_event_disconnect_marks_combined_health_stale(self):
        service = HerdrService(FakeClient([snapshot_with_status()]), environ={})
        service.refresh_snapshot()
        service._handle_stream_state("connected", None)
        self.assertTrue(service.health_response()["herdr"]["connected"])

        service._handle_stream_state("disconnected", RuntimeError("event socket closed"))
        health = service.health_response()

        self.assertTrue(health["herdr"]["requestConnected"])
        self.assertFalse(health["herdr"]["eventsConnected"])
        self.assertFalse(health["herdr"]["connected"])
        self.assertTrue(health["cache"]["stale"])

    def test_terminal_observer_slots_are_bounded_and_reusable(self):
        service = HerdrService(
            FakeClient([snapshot_with_status()]),
            environ={"HERDR_HARNESS_TERMINAL_MAX_STREAMS": "1"},
        )
        observer = object()
        with patch("herdr_harness.service.TerminalObserver", return_value=observer):
            self.assertIs(service.terminal_observer("w1:p1", cols=100, rows=32), observer)
            with self.assertRaises(TerminalObserverError):
                service.terminal_observer("w1:p1", cols=100, rows=32)
            service.release_terminal_observer()
            self.assertIs(service.terminal_observer("w1:p1", cols=100, rows=32), observer)
            service.release_terminal_observer()

    def test_mutation_returns_native_result_and_refreshes_cache(self):
        client = FakeClient([snapshot_with_status()])
        service = HerdrService(client, environ={})

        response = service.invoke("pane.focus", {"pane_id": "w1:p1"})

        self.assertEqual(response, {"ok": True, "result": {"type": "ok", "future_result": True}})
        self.assertEqual(client.requests, [("pane.focus", {"pane_id": "w1:p1"})])
        self.assertEqual(service.snapshot_response()["snapshot"]["protocol"], 19)

    def test_workspace_tools_resolve_root_only_from_cached_workspace(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            checkout = Path(temp_dir) / "checkout"
            pane_cwd = checkout / "Sources"
            pane_cwd.mkdir(parents=True)
            raw = snapshot_with_status()
            raw["workspaces"][0]["worktree"] = {"checkout_path": str(checkout)}
            raw["panes"][0]["foreground_cwd"] = str(pane_cwd)
            tools = Mock()
            tools.git_status.return_value = {
                "ok": True,
                "cwd": str(checkout),
                "branch": "feature",
                "staged": [],
                "unstaged": [],
                "untracked": [],
                "commits": [],
            }
            service = HerdrService(FakeClient([raw]), environ={}, tools=tools)
            service.refresh_snapshot()

            payload = service.workspace_git_status("w1")

            tools.git_status.assert_called_once_with(checkout.resolve())
            self.assertEqual(payload["workspace_id"], "w1")
            self.assertEqual(payload["branch"], "feature")

    def test_attachment_base64_and_decoded_size_validation_remains_bounded(self):
        with self.assertRaises(attachments.AttachmentError):
            HerdrService._decode_attachment("!!!")
        with patch("herdr_harness.attachments.MAX_ATTACHMENT_BYTES", 3):
            with self.assertRaises(attachments.AttachmentError) as context:
                HerdrService._decode_attachment(base64.b64encode(b"1234").decode())
        self.assertEqual(context.exception.status, 413)
        self.assertEqual(context.exception.code, "attachment_too_large")

    def test_alert_transition_queues_optional_push_without_blocking(self):
        client = FakeClient([snapshot_with_status("working"), snapshot_with_status("blocked")])
        push = FakePush()
        service = HerdrService(client, environ={}, push=push)

        service.refresh_snapshot()
        service.refresh_snapshot()

        self.assertEqual(len(push.alerts), 1)
        self.assertEqual(push.alerts[0][0]["status"], "blocked")
        self.assertEqual(push.alerts[0][1], 1)

    def test_alert_store_persists_journal_read_state_and_transition_baseline(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "alerts.json"
            first_store = AlertStore(store_path=store_path)
            first_service = HerdrService(
                FakeClient(
                    [snapshot_with_status("working"), snapshot_with_status("blocked")]
                ),
                alerts=first_store,
                push=FakePush(),
                environ={},
            )

            first_service.refresh_snapshot()
            first_service.refresh_snapshot()
            blocked = first_service.list_alerts(
                unread_only=False,
                status=None,
                limit=10,
            )["alerts"][0]
            first_service.mark_alert_read(blocked["id"])

            self.assertEqual(stat.S_IMODE(store_path.stat().st_mode), 0o600)
            persisted = json.loads(store_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["statusByPane"], {"w1:p1": "blocked"})
            self.assertTrue(persisted["alerts"][0]["isRead"])

            restarted_service = HerdrService(
                FakeClient(
                    [
                        snapshot_with_status("blocked"),
                        snapshot_with_status("working"),
                        snapshot_with_status("done"),
                    ]
                ),
                alerts=AlertStore(store_path=store_path),
                push=FakePush(),
                environ={},
            )
            restarted_service.refresh_snapshot()
            restarted_service.refresh_snapshot()
            restarted_service.refresh_snapshot()

            alerts = restarted_service.list_alerts(
                unread_only=False,
                status=None,
                limit=10,
            )["alerts"]
            self.assertEqual([item["status"] for item in alerts], ["done", "blocked"])
            self.assertFalse(alerts[0]["isRead"])
            self.assertTrue(alerts[1]["isRead"])
            self.assertEqual(restarted_service.alerts.unread_count(), 1)

    def test_alert_store_defensively_loads_a_bounded_journal(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "alerts.json"
            store_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "alerts": [
                            {
                                "id": f"alert_{index}",
                                "status": "blocked",
                                "isRead": index % 2 == 0,
                            }
                            for index in range(14)
                        ]
                        + ["invalid", {"id": "wrong-status", "status": "working"}],
                        "statusByPane": {
                            "w1:p1": "working",
                            "invalid": {"not": "a status"},
                        },
                    }
                ),
                encoding="utf-8",
            )
            store_path.chmod(0o644)

            store = AlertStore(maximum=10, store_path=store_path)

            self.assertEqual(
                [item["id"] for item in store.list(limit=100)],
                [f"alert_{index}" for index in range(13, 3, -1)],
            )
            self.assertEqual(stat.S_IMODE(store_path.stat().st_mode), 0o600)

            store_path.write_text("{not-json", encoding="utf-8")
            malformed = AlertStore(store_path=store_path)
            self.assertEqual(malformed.list(limit=10), [])
            self.assertEqual(malformed.unread_count(), 0)


if __name__ == "__main__":
    unittest.main()
