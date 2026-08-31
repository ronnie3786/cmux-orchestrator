import base64
import copy
import inspect
import json
import os
import sqlite3
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import herdr_harness
from herdr_harness import attachments, workspace_tools
from herdr_harness.alerts import AlertStore
from herdr_harness.client import HerdrClientError
from herdr_harness.pi_semantic import PI_SEMANTIC_PROTOCOL, PiSemanticJournal, PiSemanticManager
from herdr_harness.panes_seen import PaneFirstSeenStore
from herdr_harness.service import HerdrService
from herdr_harness.stars import StarStore
from herdr_harness.terminal import TerminalObserver, TerminalObserverError


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


def snapshot_with_statuses(first="working", second="working"):
    snapshot = snapshot_with_status(first)
    pane = copy.deepcopy(snapshot["panes"][0])
    pane.update({"pane_id": "w1:p2", "terminal_id": "term_2", "agent_status": second, "focused": False})
    agent = copy.deepcopy(snapshot["agents"][0])
    agent.update({"pane_id": "w1:p2", "terminal_id": "term_2", "agent_status": second, "focused": False})
    snapshot["panes"].append(pane)
    snapshot["agents"].append(agent)
    snapshot["workspaces"][0]["pane_count"] = 2
    snapshot["tabs"][0]["pane_count"] = 2
    return snapshot


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


class FakeQuickSessionClient:
    def __init__(self, snapshot, responses):
        self._snapshot = copy.deepcopy(snapshot)
        self.responses = responses
        self.socket_path = "/private/tmp/fake-herdr.sock"
        self.session = "quick-session-fixtures"
        self.requests = []
        self.snapshot_calls = 0

    def snapshot(self):
        self.snapshot_calls += 1
        return copy.deepcopy(self._snapshot)

    def request(self, method, params):
        self.requests.append((method, copy.deepcopy(params)))
        response = self.responses.get(method, {"ok": True})
        if isinstance(response, Exception):
            raise response
        return response(params) if callable(response) else copy.deepcopy(response)

    def subscribe_forever(self, *_args, **_kwargs):
        return None


class FakeReadyPiSemantic:
    def __init__(self, session_id=None, *, connected=True):
        self.session_id = session_id
        self.connected = connected
        self.start_calls = 0
        self.capability_calls = []
        self.snapshots = []

    def start(self):
        self.start_calls += 1

    def sync_snapshot(self, snapshot):
        self.snapshots.append(copy.deepcopy(snapshot))

    def capability(self, pane_id):
        self.capability_calls.append(pane_id)
        return {"connected": self.connected, "session_id": self.session_id}


class FakeFailingPiSemantic(FakeReadyPiSemantic):
    def __init__(self, *, failures=1):
        super().__init__()
        self.failures = failures
        self.stop_calls = 0

    def start(self):
        self.start_calls += 1
        if self.start_calls <= self.failures:
            raise RuntimeError("semantic start failed")

    def stop(self):
        self.stop_calls += 1


class FakePush:
    def __init__(self):
        self.alerts = []
        self.pulses = []

    def notify_alert_async(self, alert, *, unread_count, callback=None):
        self.alerts.append((copy.deepcopy(alert), unread_count))
        return True

    def configuration(self):
        return {"configured": False, "deviceCount": 0}

    def register(self, device_token, *, bundle_id, environment):
        return {"ok": True, "registered": True}

    def unregister(self, device_token):
        return {"ok": True, "unregistered": True}

    def notify_herd_pulse_async(
        self,
        content_state,
        *,
        force=False,
        activity_id=None,
        callback=None,
    ):
        self.pulses.append((copy.deepcopy(content_state), force, activity_id))
        return True

    def register_live_activity(self, push_token, *, activity_id, bundle_id, environment):
        return {"ok": True, "registered": True, "activity": {"activityId": activity_id}}

    def unregister_live_activity(self, activity_id, *, push_token=None):
        return {"ok": True, "unregistered": True}


class HerdrServiceTests(unittest.TestCase):
    def test_herd_pulse_is_an_aggregate_without_session_identity(self):
        push = FakePush()
        service = HerdrService(FakeClient([snapshot_with_status("blocked")]), push=push, environ={})

        service.refresh_snapshot()

        state = push.pulses[-1][0]
        self.assertEqual(state["workspaceCount"], 1)
        self.assertEqual(state["paneCount"], 1)
        self.assertEqual(state["attentionCount"], 1)
        self.assertEqual(state["phase"], "offline")
        encoded = json.dumps(state)
        self.assertNotIn("Feature Lab", encoded)
        self.assertNotIn("w1:p1", encoded)
        self.assertNotIn("Implement settings", encoded)

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

        single_workspace = service.workspace_response("w1")
        self.assertIsNotNone(single_workspace)
        self.assertEqual(single_workspace["workspace"]["tabs"][0]["future_tab_field"], 7)
        self.assertEqual(single_workspace["workspace"]["panes"][0]["future_pane_field"], [1, 2])

    def test_acknowledging_done_pane_projects_it_as_idle_in_workspaces_response(self):
        service = HerdrService(FakeClient([snapshot_with_status("done")]), environ={})
        service.refresh_snapshot()

        service.mark_pane_alerts_read("w1:p1")

        pane = service.workspaces_response()["workspaces"][0]["panes"][0]
        self.assertEqual(pane["agent_status"], "idle")

    def test_acked_done_pane_rederives_done_workspace_and_tab_statuses(self):
        service = HerdrService(
            FakeClient([snapshot_with_statuses("done", "working")]),
            environ={},
        )
        service.refresh_snapshot()

        service.mark_pane_alerts_read("w1:p1")

        workspace = service.workspaces_response()["workspaces"][0]
        self.assertEqual(workspace["agent_status"], "working")
        self.assertEqual(workspace["tabs"][0]["agent_status"], "working")

    def test_blocked_panes_are_not_projected_by_alert_acknowledgement(self):
        service = HerdrService(FakeClient([snapshot_with_status("blocked")]), environ={})
        service.refresh_snapshot()

        service.mark_pane_alerts_read("w1:p1")

        self.assertNotIn("w1:p1", service.alerts.acked_done_panes())
        pane = service.workspaces_response()["workspaces"][0]["panes"][0]
        self.assertEqual(pane["agent_status"], "blocked")

    def test_done_acknowledgement_rearms_after_an_intervening_status_change(self):
        service = HerdrService(
            FakeClient(
                [
                    snapshot_with_status("working"),
                    snapshot_with_status("done"),
                    snapshot_with_status("working"),
                    snapshot_with_status("done"),
                ]
            ),
            environ={},
        )
        service.refresh_snapshot()
        service.refresh_snapshot()
        service.mark_pane_alerts_read("w1:p1")
        self.assertEqual(
            service.workspaces_response()["workspaces"][0]["panes"][0]["agent_status"],
            "idle",
        )

        service.refresh_snapshot()
        service.refresh_snapshot()

        self.assertEqual(
            service.workspaces_response()["workspaces"][0]["panes"][0]["agent_status"],
            "done",
        )

    def test_herd_pulse_ready_count_excludes_acknowledged_done_panes(self):
        push = FakePush()
        service = HerdrService(
            FakeClient([snapshot_with_status("done")]),
            push=push,
            environ={},
        )
        service.refresh_snapshot()
        self.assertEqual(push.pulses[-1][0]["readyCount"], 1)

        service.mark_pane_alerts_read("w1:p1")
        service._publish_herd_pulse(force=True)

        self.assertEqual(push.pulses[-1][0]["readyCount"], 0)

    def test_workspaces_response_includes_first_seen_at_for_refreshed_panes(self):
        service = HerdrService(FakeClient([snapshot_with_status("working")]), environ={})
        service.refresh_snapshot()

        pane = service.workspaces_response()["workspaces"][0]["panes"][0]
        self.assertIsInstance(pane["first_seen_at"], str)
        self.assertEqual(pane["last_activity_at"], pane["first_seen_at"])
        self.assertEqual(pane["working_since"], pane["first_seen_at"])

    def test_pane_first_seen_store_persists_across_service_restart(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "pane-first-seen.json"
            first_service = HerdrService(
                FakeClient([snapshot_with_status("working")]),
                panes_seen=PaneFirstSeenStore(store_path=store_path),
                environ={},
            )
            first_service.refresh_snapshot()
            first_seen_at = first_service.panes_seen.first_seen_map()["w1:p1"]

            self.assertEqual(stat.S_IMODE(store_path.stat().st_mode), 0o600)

            second_service = HerdrService(
                FakeClient([snapshot_with_status("working")]),
                panes_seen=PaneFirstSeenStore(store_path=store_path),
                environ={},
            )

            self.assertEqual(second_service.panes_seen.first_seen_map()["w1:p1"], first_seen_at)

    def test_refresh_snapshot_prunes_first_seen_timestamp_for_disappeared_pane(self):
        missing_pane = snapshot_with_status("working")
        missing_pane["panes"] = []
        missing_pane["agents"] = []
        missing_pane["workspaces"][0]["pane_count"] = 0
        missing_pane["tabs"][0]["pane_count"] = 0
        service = HerdrService(
            FakeClient([snapshot_with_status("working"), missing_pane]),
            environ={},
        )
        service.refresh_snapshot()
        self.assertIn("w1:p1", service.panes_seen.first_seen_map())

        service.refresh_snapshot()

        self.assertNotIn("w1:p1", service.panes_seen.first_seen_map())

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

    def test_focusing_pane_marks_only_that_panes_alerts_read(self):
        client = FakeClient(
            [
                snapshot_with_statuses("working", "working"),
                snapshot_with_statuses("blocked", "blocked"),
            ]
        )
        service = HerdrService(client, environ={})
        service.refresh_snapshot()
        service.refresh_snapshot()
        before = service.broker.latest_id

        service._handle_event({"event": "pane.focused", "data": {"pane_id": "w1:p1"}})

        alerts = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"]
        by_pane = {alert["paneId"]: alert for alert in alerts}
        self.assertTrue(by_pane["w1:p1"]["isRead"])
        self.assertFalse(by_pane["w1:p2"]["isRead"])
        events = service.broker.after(before)
        aggregate = [item for item in events if item["event"] == "alerts.read_state_changed"]
        self.assertEqual(len(aggregate), 1)
        self.assertEqual(aggregate[0]["data"]["unread_count"], service.alerts.unread_count())
        self.assertFalse(any(item["event"] == "alert.updated" for item in events))

    def test_mark_all_alerts_read_publishes_one_aggregate_event_without_per_alert_events(self):
        client = FakeClient(
            [
                snapshot_with_statuses("working", "working"),
                snapshot_with_statuses("blocked", "blocked"),
            ]
        )
        service = HerdrService(client, environ={})
        service.refresh_snapshot()
        service.refresh_snapshot()
        before = service.broker.latest_id

        result = service.mark_all_alerts_read()

        self.assertEqual(len(result["alerts"]), 2)
        events = service.broker.after(before)
        self.assertEqual(
            sum(item["event"] == "alerts.read_state_changed" for item in events),
            1,
        )
        self.assertFalse(any(item["event"] == "alert.updated" for item in events))

    def test_mark_pane_alerts_read_marks_only_that_panes_alerts_and_is_idempotent(self):
        client = FakeClient(
            [
                snapshot_with_statuses("working", "working"),
                snapshot_with_statuses("blocked", "blocked"),
            ]
        )
        service = HerdrService(client, environ={})
        service.refresh_snapshot()
        service.refresh_snapshot()
        before = service.broker.latest_id

        result = service.mark_pane_alerts_read("w1:p1")

        alerts = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"]
        by_pane = {alert["paneId"]: alert for alert in alerts}
        self.assertTrue(result["ok"])
        self.assertEqual(result["paneId"], "w1:p1")
        self.assertEqual(len(result["alerts"]), 1)
        self.assertEqual(result["unreadCount"], service.alerts.unread_count())
        self.assertTrue(result["alerts"][0]["isRead"])
        self.assertTrue(by_pane["w1:p1"]["isRead"])
        self.assertFalse(by_pane["w1:p2"]["isRead"])

        second_result = service.mark_pane_alerts_read("w1:p1")

        self.assertEqual(second_result["alerts"], [])
        self.assertEqual(second_result["unreadCount"], service.alerts.unread_count())
        events = service.broker.after(before)
        self.assertEqual(
            sum(item["event"] == "alerts.read_state_changed" for item in events),
            1,
        )
        self.assertFalse(any(item["event"] == "alert.updated" for item in events))

    def test_mark_pane_alerts_read_returns_none_for_unknown_pane(self):
        service = HerdrService(FakeClient([snapshot_with_status("working")]), environ={})
        service.refresh_snapshot()

        self.assertIsNone(service.mark_pane_alerts_read("nonexistent-pane"))

    def test_mark_alert_read_publishes_per_alert_and_aggregate_events(self):
        client = FakeClient([snapshot_with_status("working"), snapshot_with_status("blocked")])
        service = HerdrService(client, environ={})
        service.refresh_snapshot()
        service.refresh_snapshot()
        alert_id = service.list_alerts(unread_only=True, status=None, limit=10)["alerts"][0]["id"]
        before = service.broker.latest_id

        result = service.mark_alert_read(alert_id)

        self.assertTrue(result["ok"])
        events = service.broker.after(before)
        self.assertEqual(sum(item["event"] == "alert.updated" for item in events), 1)
        self.assertEqual(
            sum(item["event"] == "alerts.read_state_changed" for item in events),
            1,
        )

    def test_blocked_to_working_transition_auto_marks_alert_read(self):
        service = HerdrService(
            FakeClient(
                [
                    snapshot_with_status("working"),
                    snapshot_with_status("blocked"),
                    snapshot_with_status("working"),
                ]
            ),
            environ={},
        )
        service.refresh_snapshot()
        service.refresh_snapshot()

        service.refresh_snapshot()

        alert = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"][0]
        self.assertTrue(alert["isRead"])
        self.assertIsNotNone(alert["readAt"])

    def test_done_to_idle_transition_auto_marks_alert_read(self):
        service = HerdrService(
            FakeClient(
                [
                    snapshot_with_status("working"),
                    snapshot_with_status("done"),
                    snapshot_with_status("idle"),
                ]
            ),
            environ={},
        )
        service.refresh_snapshot()
        service.refresh_snapshot()

        service.refresh_snapshot()

        alert = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"][0]
        self.assertTrue(alert["isRead"])

    def test_transition_out_persists_auto_read_batch_once(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = AlertStore(store_path=Path(temp_dir) / "alerts.json")
            service = HerdrService(
                FakeClient(
                    [
                        snapshot_with_status("working"),
                        snapshot_with_status("blocked"),
                        snapshot_with_status("working"),
                    ]
                ),
                alerts=store,
                environ={},
            )
            service.refresh_snapshot()
            service.refresh_snapshot()

            with patch.object(store, "_write", wraps=store._write) as write:
                service.refresh_snapshot()

            write.assert_called_once()

    def test_pruned_pane_auto_marks_its_alerts_read(self):
        missing_pane = snapshot_with_status("working")
        missing_pane["panes"] = []
        missing_pane["agents"] = []
        missing_pane["workspaces"][0]["pane_count"] = 0
        missing_pane["tabs"][0]["pane_count"] = 0
        service = HerdrService(
            FakeClient(
                [
                    snapshot_with_status("working"),
                    snapshot_with_status("blocked"),
                    missing_pane,
                ]
            ),
            environ={},
        )
        service.refresh_snapshot()
        service.refresh_snapshot()

        service.refresh_snapshot()

        alert = service.list_alerts(unread_only=False, status=None, limit=10)["alerts"][0]
        self.assertTrue(alert["isRead"])

    def test_cached_snapshot_survives_disconnect_and_health_marks_it_stale(self):
        client = FakeClient([snapshot_with_status()])
        push = FakePush()
        service = HerdrService(client, push=push, environ={})
        service.refresh_snapshot()
        service._handle_stream_state("connected", None)
        self.assertEqual(push.pulses[-1][0]["connection"], "live")
        client.fail = True

        with self.assertRaises(HerdrClientError):
            service.refresh_snapshot()

        self.assertEqual(push.pulses[-1][0]["connection"], "offline")
        self.assertEqual(push.pulses[-1][0]["phase"], "offline")
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

    def test_start_failure_resets_started_state_and_retries_semantic_start(self):
        semantic = FakeFailingPiSemantic(failures=2)
        service = HerdrService(
            FakeQuickSessionClient(snapshot_with_status(), {}),
            environ={},
            pi_semantic=semantic,
        )

        for expected_calls in (1, 2):
            with self.assertRaises(HerdrClientError) as context:
                service.start()
            self.assertEqual(context.exception.code, "quick_session_not_ready")
            self.assertFalse(service._started)
            self.assertEqual(semantic.start_calls, expected_calls)
            self.assertEqual(semantic.stop_calls, expected_calls)

        self.assertIsNone(service._event_thread)
        self.assertIsNone(service._refresh_thread)

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

    def test_quick_pi_session_creates_named_workspace_and_renames_root_tab(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {
                "workspace.create": {
                    "workspace": {"workspace_id": "w-random", "active_tab_id": "w-random:t1"},
                    "pane": {"pane_id": "w-random:p1", "tab_id": "w-random:t1"},
                }
            },
        )
        with tempfile.TemporaryDirectory() as extension_path:
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": extension_path},
            )
            result = service.quick_pi_session("aug 18, 2:34 pm")

        self.assertEqual(
            client.requests[0],
            (
                "workspace.create",
                {"label": "Random", "cwd": str(Path.home().resolve()), "focus": True},
            ),
        )
        self.assertEqual(
            result,
            {
                "ok": True,
                "workspace_id": "w-random",
                "tab_id": "w-random:t1",
                "pane_id": "w-random:p1",
                "created_workspace": True,
                "created_tab": True,
                "created_pane": True,
                "pi_extension_attached": True,
                "pi_semantic_ready": False,
                "request_id": None,
                "session_id": None,
            },
        )
        self.assertEqual(
            client.requests[1],
            ("tab.rename", {"tab_id": "w-random:t1", "label": "One-off Tasks"}),
        )
        self.assertEqual(
            client.requests[2][1],
            {
                "pane_id": "w-random:p1",
                "name": client.requests[2][1]["name"],
                "kind": "pi",
                "args": ["--extension", extension_path],
                "timeout_ms": 30000,
            },
        )
        self.assertRegex(client.requests[2][1]["name"], r"^quick-pi-[a-z0-9]{8}$")
        self.assertEqual(
            client.requests[3],
            ("pane.rename", {"pane_id": "w-random:p1", "label": "aug 18, 2:34 pm"}),
        )
        self.assertEqual(client.snapshot_calls, 2)

    def test_quick_pi_session_accepts_root_pane_from_workspace_create(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {
                "workspace.create": {
                    "workspace": {"workspace_id": "w-random", "active_tab_id": "w-random:t1"},
                    "root_pane": {"pane_id": "w-random:p1", "tab_id": "w-random:t1"},
                }
            },
        )
        service = HerdrService(
            client,
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )

        result = service.quick_pi_session("new session")

        self.assertEqual(result["pane_id"], "w-random:p1")
        self.assertEqual(client.requests[2][1]["args"], [])
        self.assertFalse(result["pi_extension_attached"])

    def test_quick_pi_session_reuses_exact_named_workspace_and_tab_by_splitting(self):
        client = FakeQuickSessionClient(
            {
                "workspaces": [{"workspace_id": "w-existing", "number": 2, "label": "Random"}],
                "tabs": [
                    {
                        "tab_id": "w-existing:t1",
                        "workspace_id": "w-existing",
                        "number": 1,
                        "label": "One-off Tasks",
                    }
                ],
                "panes": [
                    {
                        "pane_id": "w-existing:p1",
                        "workspace_id": "w-existing",
                        "tab_id": "w-existing:t1",
                        "focused": True,
                        "foreground_cwd": os.path.expanduser("~"),
                    }
                ],
            },
            {"pane.split": {"pane": {"pane_id": "w-existing:p2", "tab_id": "w-existing:t1"}}},
        )
        service = HerdrService(
            client,
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )

        result = service.quick_pi_session("new session")

        self.assertNotIn("workspace.create", [method for method, _ in client.requests])
        self.assertNotIn("tab.create", [method for method, _ in client.requests])
        self.assertEqual(
            client.requests[0],
            (
                "pane.split",
                {
                    "target_pane_id": "w-existing:p1",
                    "direction": "right",
                    "cwd": str(Path.home().resolve()),
                    "focus": True,
                },
            ),
        )
        self.assertEqual(result["workspace_id"], "w-existing")
        self.assertEqual(result["tab_id"], "w-existing:t1")
        self.assertEqual(result["pane_id"], "w-existing:p2")
        self.assertFalse(result["created_workspace"])
        self.assertFalse(result["created_tab"])

    def test_quick_pi_session_uses_fresh_snapshot_when_cached_topology_is_stale(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {"pane.split": {"pane": {"pane_id": "w-existing:p2", "tab_id": "w-existing:t1"}}},
        )
        service = HerdrService(
            client,
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )
        service.refresh_snapshot()
        client._snapshot = {
            "workspaces": [{"workspace_id": "w-existing", "label": "Random"}],
            "tabs": [
                {
                    "tab_id": "w-existing:t1",
                    "workspace_id": "w-existing",
                    "label": "One-off Tasks",
                }
            ],
            "panes": [
                {
                    "pane_id": "w-existing:p1",
                    "workspace_id": "w-existing",
                    "tab_id": "w-existing:t1",
                    "cwd": str(Path.home().resolve()),
                }
            ],
        }

        with patch.object(service, "refresh_snapshot", wraps=service.refresh_snapshot) as refresh_snapshot:
            result = service.quick_pi_session("new session")

        self.assertGreaterEqual(refresh_snapshot.call_count, 1)
        self.assertNotIn("workspace.create", [method for method, _ in client.requests])
        self.assertEqual(result["workspace_id"], "w-existing")
        self.assertFalse(result["created_workspace"])

    def test_quick_pi_session_creates_named_tab_in_explicit_workspace_and_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "home"
            target = Path(directory) / "project"
            home.mkdir()
            target.mkdir()
            client = FakeQuickSessionClient(
                {"workspaces": [{"workspace_id": "w-target", "label": "Project"}], "tabs": [], "panes": []},
                {
                    "tab.create": {
                        "tab": {
                            "tab_id": "w-target:t2",
                            "root_pane": {"pane_id": "w-target:p2", "tab_id": "w-target:t2"},
                        }
                    }
                },
            )
            service = HerdrService(
                client,
                environ={
                    "HOME": str(home),
                    "HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge",
                },
            )

            result = service.quick_pi_session(
                "new session",
                workspace_id="w-target",
                cwd=str(target),
            )

        self.assertEqual(
            client.requests[0],
            (
                "tab.create",
                {
                    "workspace_id": "w-target",
                    "cwd": str(target.resolve()),
                    "focus": True,
                    "label": "One-off Tasks",
                },
            ),
        )
        self.assertFalse(result["created_workspace"])
        self.assertTrue(result["created_tab"])
        self.assertEqual(result["tab_id"], "w-target:t2")

    def test_quick_pi_session_explicit_workspace_inherits_its_cwd_when_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace_cwd = Path(directory) / "workspace"
            workspace_cwd.mkdir()
            client = FakeQuickSessionClient(
                {
                    "workspaces": [
                        {"workspace_id": "w-target", "label": "Project", "cwd": str(workspace_cwd)}
                    ],
                    "tabs": [],
                    "panes": [],
                },
                {
                    "tab.create": {
                        "tab": {
                            "tab_id": "w-target:t2",
                            "root_pane": {"pane_id": "w-target:p2", "tab_id": "w-target:t2"},
                        }
                    }
                },
            )
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
            )

            service.quick_pi_session("new session", workspace_id="w-target")

        tab_request = next(params for method, params in client.requests if method == "tab.create")
        self.assertEqual(tab_request["cwd"], str(workspace_cwd.resolve()))

    def test_quick_pi_session_name_match_is_exact_and_independent_of_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "home"
            project = Path(directory) / "project"
            home.mkdir()
            project.mkdir()
            client = FakeQuickSessionClient(
                {
                    "workspaces": [
                        {"workspace_id": "w-project", "label": "random"}
                    ],
                    "tabs": [],
                    "panes": [
                        {
                            "pane_id": "w-project:p1",
                            "workspace_id": "w-project",
                            "cwd": str(project),
                        }
                    ],
                },
                {
                    "workspace.create": {
                        "workspace": {"workspace_id": "w-home", "active_tab_id": "w-home:t1"},
                        "pane": {"pane_id": "w-home:p1", "tab_id": "w-home:t1"},
                    }
                },
            )
            service = HerdrService(
                client,
                environ={
                    "HOME": str(home),
                    "HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge",
                },
            )

            result = service.quick_pi_session("new session")

        self.assertEqual(
            client.requests[0],
            (
                "workspace.create",
                {
                    "label": "Random",
                    "cwd": str(home.resolve()),
                    "focus": True,
                },
            ),
        )
        self.assertTrue(result["created_workspace"])

        exact_client = FakeQuickSessionClient(
            {
                "workspaces": [{"workspace_id": "w-project", "label": "Random"}],
                "tabs": [],
                "panes": [
                    {
                        "pane_id": "w-project:p1",
                        "workspace_id": "w-project",
                        "tab_id": "w-project:t1",
                        "cwd": str(project),
                    }
                ],
            },
            {
                "tab.create": {
                    "tab": {
                        "tab_id": "w-project:t2",
                        "root_pane": {"pane_id": "w-project:p2", "tab_id": "w-project:t2"},
                    }
                }
            },
        )
        exact_service = HerdrService(
            exact_client,
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )
        exact_result = exact_service.quick_pi_session("new session")
        self.assertEqual(exact_result["workspace_id"], "w-project")
        self.assertNotIn("workspace.create", [method for method, _ in exact_client.requests])

    def test_quick_pi_session_explicit_tab_infers_workspace_and_validates_pair(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-target", "label": "Project"}],
            "tabs": [{"tab_id": "w-target:t1", "workspace_id": "w-target", "label": "Build"}],
            "panes": [
                {"pane_id": "w-target:p1", "workspace_id": "w-target", "tab_id": "w-target:t1"}
            ],
        }
        client = FakeQuickSessionClient(
            snapshot,
            {"pane.split": {"pane": {"pane_id": "w-target:p2", "tab_id": "w-target:t1"}}},
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        result = service.quick_pi_session("continued session", tab_id="w-target:t1")

        self.assertEqual(result["workspace_id"], "w-target")
        self.assertEqual(result["tab_id"], "w-target:t1")
        with self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session(
                "bad target",
                workspace_id="w-other",
                tab_id="w-target:t1",
            )
        self.assertEqual(context.exception.code, "quick_session_target_conflict")

    def test_quick_pi_session_rejects_an_explicit_missing_workspace(self):
        service = HerdrService(
            FakeQuickSessionClient({"workspaces": []}, {}),
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )

        with self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session("new session", workspace_id="w-missing")

        self.assertEqual(context.exception.code, "workspace_not_found")

    def test_quick_pi_session_ignores_pane_rename_failure(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {
                "workspace.create": {
                    "workspace": {"workspace_id": "w-random", "active_tab_id": "w-random:t1"},
                    "pane": {"pane_id": "w-random:p1", "tab_id": "w-random:t1"},
                },
                "pane.rename": HerdrClientError("rename failed", code="herdr_unavailable"),
            },
        )
        service = HerdrService(
            client,
            environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
        )

        result = service.quick_pi_session("new session")

        self.assertTrue(result["ok"])
        self.assertEqual(client.requests[-1], ("pane.rename", {"pane_id": "w-random:p1", "label": "new session"}))

    def test_quick_pi_session_rolls_back_created_workspace_when_tab_rename_fails(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {
                "workspace.create": {
                    "workspace": {"workspace_id": "w-random", "active_tab_id": "w-random:t1"},
                    "pane": {"pane_id": "w-random:p1", "tab_id": "w-random:t1"},
                },
                "tab.rename": HerdrClientError("rename failed", code="herdr_unavailable"),
            },
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with self.assertRaises(HerdrClientError):
            service.quick_pi_session("new session")

        self.assertIn(("workspace.close", {"workspace_id": "w-random"}), client.requests)
        self.assertNotIn("agent.start", [method for method, _ in client.requests])

    def test_quick_pi_session_rolls_back_split_pane_when_agent_start_fails(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [
                {"tab_id": "w-random:t1", "workspace_id": "w-random", "label": "One-off Tasks"}
            ],
            "panes": [
                {"pane_id": "w-random:p1", "workspace_id": "w-random", "tab_id": "w-random:t1"}
            ],
        }
        client = FakeQuickSessionClient(
            snapshot,
            {
                "pane.split": {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}},
                "agent.start": HerdrClientError("start failed", code="herdr_unavailable"),
            },
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with self.assertRaises(HerdrClientError):
            service.quick_pi_session("new session")

        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)

    def test_quick_pi_session_uses_topology_diff_when_split_response_echoes_anchor(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [
                {"tab_id": "w-random:t1", "workspace_id": "w-random", "label": "One-off Tasks"}
            ],
            "panes": [
                {"pane_id": "w-random:p1", "workspace_id": "w-random", "tab_id": "w-random:t1"}
            ],
            "agents": [],
        }
        client = FakeQuickSessionClient(snapshot, {})

        def split_echoing_anchor(_params):
            client._snapshot["panes"].append(
                {
                    "pane_id": "w-random:p2",
                    "workspace_id": "w-random",
                    "tab_id": "w-random:t1",
                }
            )
            return {
                "pane": {
                    "pane_id": "w-random:p1",
                    "workspace_id": "w-random",
                    "tab_id": "w-random:t1",
                }
            }

        client.responses.update(
            {
                "pane.split": split_echoing_anchor,
                "agent.start": HerdrClientError("start failed", code="herdr_unavailable"),
            }
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with self.assertRaises(HerdrClientError):
            service.quick_pi_session("new session")

        start_request = next(params for method, params in client.requests if method == "agent.start")
        self.assertEqual(start_request["pane_id"], "w-random:p2")
        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)
        self.assertNotIn(("pane.close", {"pane_id": "w-random:p1"}), client.requests)

    def test_quick_pi_session_retries_busy_pane_until_late_success(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [
                {"tab_id": "w-random:t1", "workspace_id": "w-random", "label": "One-off Tasks"}
            ],
            "panes": [
                {"pane_id": "w-random:p1", "workspace_id": "w-random", "tab_id": "w-random:t1"}
            ],
            "agents": [],
        }
        client = FakeQuickSessionClient(snapshot, {})
        start_attempts = 0

        def split(_params):
            client._snapshot["panes"].append(
                {
                    "pane_id": "w-random:p2",
                    "workspace_id": "w-random",
                    "tab_id": "w-random:t1",
                }
            )
            return {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}

        def busy_then_start(_params):
            nonlocal start_attempts
            start_attempts += 1
            if start_attempts <= 20:
                if start_attempts == 1:
                    client._snapshot["panes"].pop()
                raise HerdrClientError("pane is not ready", code="agent_pane_busy")
            return {"ok": True}

        def publish_delayed_pane(_seconds):
            if not any(item.get("pane_id") == "w-random:p2" for item in client._snapshot["panes"]):
                client._snapshot["panes"].append(
                    {
                        "pane_id": "w-random:p2",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    }
                )

        client.responses.update({"pane.split": split, "agent.start": busy_then_start})
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with patch("herdr_harness.service.time.sleep", side_effect=publish_delayed_pane):
            result = service.quick_pi_session("new session")

        self.assertEqual(result["pane_id"], "w-random:p2")
        self.assertEqual(start_attempts, 21)
        self.assertNotIn("pane.close", [method for method, _ in client.requests])

    def test_quick_pi_session_exhausts_busy_retry_window_then_closes_owned_pane(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [
                {"tab_id": "w-random:t1", "workspace_id": "w-random", "label": "One-off Tasks"}
            ],
            "panes": [
                {"pane_id": "w-random:p1", "workspace_id": "w-random", "tab_id": "w-random:t1"}
            ],
            "agents": [],
        }
        client = FakeQuickSessionClient(snapshot, {})

        def split(_params):
            client._snapshot["panes"].append(
                {
                    "pane_id": "w-random:p2",
                    "workspace_id": "w-random",
                    "tab_id": "w-random:t1",
                }
            )
            return {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}

        client.responses.update(
            {
                "pane.split": split,
                "agent.start": HerdrClientError("pane stayed busy", code="agent_pane_busy"),
            }
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with patch("herdr_harness.service.time.sleep"), self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session("new session")

        self.assertEqual(context.exception.code, "agent_pane_busy")
        self.assertEqual(sum(method == "agent.start" for method, _ in client.requests), 41)
        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)
        self.assertNotIn(("pane.close", {"pane_id": "w-random:p1"}), client.requests)

    def test_quick_pi_session_does_not_retry_or_close_a_claimed_moved_or_missing_pane(self):
        for changed_state in ("claimed", "moved", "missing"):
            with self.subTest(changed_state=changed_state):
                snapshot = {
                    "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
                    "tabs": [
                        {
                            "tab_id": "w-random:t1",
                            "workspace_id": "w-random",
                            "label": "One-off Tasks",
                        }
                    ],
                    "panes": [
                        {
                            "pane_id": "w-random:p1",
                            "workspace_id": "w-random",
                            "tab_id": "w-random:t1",
                        }
                    ],
                    "agents": [],
                }
                client = FakeQuickSessionClient(snapshot, {})

                def split(_params):
                    client._snapshot["panes"].append(
                        {
                            "pane_id": "w-random:p2",
                            "workspace_id": "w-random",
                            "tab_id": "w-random:t1",
                        }
                    )
                    return {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}

                def claim_or_move(_params):
                    if changed_state == "claimed":
                        client._snapshot["agents"].append(
                            {
                                "pane_id": "w-random:p2",
                                "workspace_id": "w-random",
                                "tab_id": "w-random:t1",
                                "agent": "pi",
                            }
                        )
                    elif changed_state == "moved":
                        client._snapshot["panes"][-1]["tab_id"] = "w-random:t-other"
                    else:
                        client._snapshot["panes"].pop()
                    raise HerdrClientError("pane was claimed", code="agent_pane_busy")

                client.responses.update({"pane.split": split, "agent.start": claim_or_move})
                service = HerdrService(
                    client,
                    environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
                )

                with patch("herdr_harness.service.time.sleep"), self.assertRaises(
                    HerdrClientError
                ) as context:
                    service.quick_pi_session("new session")

                self.assertEqual(context.exception.code, "quick_session_placement_conflict")
                self.assertEqual(sum(method == "agent.start" for method, _ in client.requests), 1)
                self.assertNotIn("pane.close", [method for method, _ in client.requests])

    def test_quick_pi_session_never_closes_preexisting_ids_echoed_by_create_responses(self):
        cases = (
            (
                {
                    "workspaces": [{"workspace_id": "w-existing", "label": "Project"}],
                    "tabs": [
                        {
                            "tab_id": "w-existing:t1",
                            "workspace_id": "w-existing",
                            "label": "Build",
                        }
                    ],
                    "panes": [
                        {
                            "pane_id": "w-existing:p1",
                            "workspace_id": "w-existing",
                            "tab_id": "w-existing:t1",
                        }
                    ],
                },
                "workspace.create",
                {
                    "workspace": {
                        "workspace_id": "w-existing",
                        "active_tab_id": "w-existing:t1",
                    },
                    "pane": {"pane_id": "w-existing:p1", "tab_id": "w-existing:t1"},
                },
                "workspace.close",
            ),
            (
                {
                    "workspaces": [{"workspace_id": "w-existing", "label": "Random"}],
                    "tabs": [
                        {
                            "tab_id": "w-existing:t1",
                            "workspace_id": "w-existing",
                            "label": "Build",
                        }
                    ],
                    "panes": [
                        {
                            "pane_id": "w-existing:p1",
                            "workspace_id": "w-existing",
                            "tab_id": "w-existing:t1",
                        }
                    ],
                },
                "tab.create",
                {
                    "tab": {
                        "tab_id": "w-existing:t1",
                        "root_pane": {
                            "pane_id": "w-existing:p1",
                            "tab_id": "w-existing:t1",
                        },
                    }
                },
                "tab.close",
            ),
        )
        for snapshot, create_method, response, close_method in cases:
            with self.subTest(create_method=create_method):
                client = FakeQuickSessionClient(snapshot, {create_method: response})
                service = HerdrService(
                    client,
                    environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"},
                )

                with self.assertRaises(HerdrClientError) as context:
                    service.quick_pi_session("new session")

                self.assertEqual(context.exception.code, "invalid_herdr_response")
                self.assertNotIn(close_method, [method for method, _ in client.requests])

    def test_quick_pi_session_rejects_ambiguous_snapshot_diff_before_starting_pi(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [
                {"tab_id": "w-random:t1", "workspace_id": "w-random", "label": "One-off Tasks"}
            ],
            "panes": [
                {"pane_id": "w-random:p1", "workspace_id": "w-random", "tab_id": "w-random:t1"}
            ],
        }
        client = FakeQuickSessionClient(snapshot, {})

        def ambiguous_split(_params):
            client._snapshot["panes"].extend(
                [
                    {
                        "pane_id": "w-random:p2",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    },
                    {
                        "pane_id": "w-random:p3",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    },
                ]
            )
            return {"ok": True}

        client.responses["pane.split"] = ambiguous_split
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session("new session")

        self.assertEqual(context.exception.code, "quick_session_placement_conflict")
        self.assertNotIn("agent.start", [method for method, _ in client.requests])
        self.assertNotIn("pane.close", [method for method, _ in client.requests])

    def test_quick_pi_session_rolls_back_created_tab_when_agent_start_fails(self):
        snapshot = {
            "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
            "tabs": [],
            "panes": [],
        }
        client = FakeQuickSessionClient(
            snapshot,
            {
                "tab.create": {
                    "tab": {
                        "tab_id": "w-random:t2",
                        "root_pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t2"},
                    }
                },
                "agent.start": HerdrClientError("start failed", code="herdr_unavailable"),
            },
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        with self.assertRaises(HerdrClientError):
            service.quick_pi_session("new session")

        self.assertIn(("tab.close", {"tab_id": "w-random:t2"}), client.requests)
        self.assertNotIn("workspace.close", [method for method, _ in client.requests])

    def test_quick_pi_session_request_id_replays_result_and_rejects_conflicts(self):
        client = FakeQuickSessionClient(
            {"workspaces": [], "tabs": [], "panes": []},
            {
                "workspace.create": {
                    "workspace": {"workspace_id": "w-random", "active_tab_id": "w-random:t1"},
                    "pane": {"pane_id": "w-random:p1", "tab_id": "w-random:t1"},
                }
            },
        )
        service = HerdrService(client, environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "/missing/bridge"})

        first = service.quick_pi_session("new session", request_id="request-1")
        second = service.quick_pi_session("new session", request_id="request-1")

        self.assertEqual(first, second)
        self.assertEqual(sum(method == "agent.start" for method, _ in client.requests), 1)
        self.assertEqual(client.snapshot_calls, 2)
        with self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session("different", request_id="request-1")
        self.assertEqual(context.exception.code, "quick_session_request_conflict")

    def test_quick_pi_session_rejects_session_id_without_file(self):
        client = FakeQuickSessionClient({"workspaces": [], "tabs": [], "panes": []}, {})
        service = HerdrService(client, environ={})

        with self.assertRaises(HerdrClientError) as context:
            service.quick_pi_session("continued", session_id="session-1")

        self.assertEqual(context.exception.code, "session_file_required")
        self.assertEqual(client.snapshot_calls, 0)
        self.assertEqual(client.requests, [])

    def test_quick_pi_session_waits_for_exact_resumed_session_before_success(self):
        with tempfile.TemporaryDirectory() as directory:
            session_file = Path(directory) / "session.jsonl"
            session_file.write_text(
                json.dumps({"type": "session", "id": "session-1", "cwd": directory}) + "\n",
                encoding="utf-8",
            )
            snapshot = {
                "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
                "tabs": [
                    {
                        "tab_id": "w-random:t1",
                        "workspace_id": "w-random",
                        "label": "One-off Tasks",
                    }
                ],
                "panes": [
                    {
                        "pane_id": "w-random:p1",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    }
                ],
            }
            client = FakeQuickSessionClient(
                snapshot,
                {"pane.split": {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}},
            )
            semantic = FakeReadyPiSemantic("session-1")
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": directory},
                pi_semantic=semantic,
            )

            result = service.quick_pi_session(
                "continued",
                session_file=str(session_file),
                session_id="session-1",
                request_id="request-1",
            )

        self.assertTrue(result["pi_semantic_ready"])
        self.assertEqual(result["session_id"], "session-1")
        self.assertEqual(semantic.start_calls, 1)
        self.assertEqual(semantic.capability_calls, ["w-random:p2"])

    def test_quick_pi_session_rolls_back_when_resumed_identity_is_wrong(self):
        with tempfile.TemporaryDirectory() as directory:
            session_file = Path(directory) / "session.jsonl"
            session_file.write_text(
                json.dumps({"type": "session", "id": "session-1", "cwd": directory}) + "\n",
                encoding="utf-8",
            )
            snapshot = {
                "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
                "tabs": [
                    {
                        "tab_id": "w-random:t1",
                        "workspace_id": "w-random",
                        "label": "One-off Tasks",
                    }
                ],
                "panes": [
                    {
                        "pane_id": "w-random:p1",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    }
                ],
            }
            client = FakeQuickSessionClient(
                snapshot,
                {"pane.split": {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}},
            )
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": directory},
                pi_semantic=FakeReadyPiSemantic("different-session"),
            )

            with self.assertRaises(HerdrClientError) as context:
                service.quick_pi_session(
                    "continued",
                    session_file=str(session_file),
                    session_id="session-1",
                )

        self.assertEqual(context.exception.code, "quick_session_identity_mismatch")
        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)

    def test_quick_pi_session_rolls_back_when_semantic_manager_cannot_start(self):
        with tempfile.TemporaryDirectory() as directory:
            session_file = Path(directory) / "session.jsonl"
            session_file.write_text(
                json.dumps({"type": "session", "id": "session-1", "cwd": directory}) + "\n",
                encoding="utf-8",
            )
            snapshot = {
                "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
                "tabs": [
                    {
                        "tab_id": "w-random:t1",
                        "workspace_id": "w-random",
                        "label": "One-off Tasks",
                    }
                ],
                "panes": [
                    {
                        "pane_id": "w-random:p1",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    }
                ],
            }
            client = FakeQuickSessionClient(
                snapshot,
                {"pane.split": {"pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}}},
            )
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": directory},
                pi_semantic=FakeFailingPiSemantic(),
            )

            with self.assertRaises(HerdrClientError) as context:
                service.quick_pi_session("continued", session_file=str(session_file))

        self.assertEqual(context.exception.code, "quick_session_not_ready")
        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)

    def test_quick_pi_session_reports_unknown_outcome_when_rollback_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            session_file = Path(directory) / "session.jsonl"
            session_file.write_text(
                json.dumps({"type": "session", "id": "session-1", "cwd": directory}) + "\n",
                encoding="utf-8",
            )
            snapshot = {
                "workspaces": [{"workspace_id": "w-random", "label": "Random"}],
                "tabs": [
                    {
                        "tab_id": "w-random:t1",
                        "workspace_id": "w-random",
                        "label": "One-off Tasks",
                    }
                ],
                "panes": [
                    {
                        "pane_id": "w-random:p1",
                        "workspace_id": "w-random",
                        "tab_id": "w-random:t1",
                    }
                ],
            }
            client = FakeQuickSessionClient(
                snapshot,
                {
                    "pane.split": {
                        "pane": {"pane_id": "w-random:p2", "tab_id": "w-random:t1"}
                    },
                    "pane.close": HerdrClientError("close timed out", code="herdr_timeout"),
                },
            )
            service = HerdrService(
                client,
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": directory},
                pi_semantic=FakeReadyPiSemantic("different-session"),
            )

            with self.assertRaises(HerdrClientError) as context:
                service.quick_pi_session("continued", session_file=str(session_file))

        self.assertEqual(context.exception.code, "quick_session_outcome_unknown")
        self.assertIn(("pane.close", {"pane_id": "w-random:p2"}), client.requests)

    def test_default_pi_extension_path_is_detected_when_present(self):
        expected_path = Path(herdr_harness.__file__).resolve().parent.parent / "pi-semantic-bridge"
        if not os.path.isdir(expected_path):
            self.skipTest("repository Pi extension is unavailable")
        service = HerdrService(
            FakeQuickSessionClient({"workspaces": []}, {}),
            environ={},
        )

        self.assertEqual(service.pi_extension_args(), ["--extension", str(expected_path)])

    def test_pi_extension_override_expands_home_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            extension_path = Path(temp_dir) / "bridge"
            extension_path.mkdir()
            service = HerdrService(
                FakeQuickSessionClient({"workspaces": []}, {}),
                environ={"HERDR_HARNESS_PI_EXTENSION_PATH": "~/bridge"},
            )

            with patch.dict(os.environ, {"HOME": temp_dir}):
                self.assertEqual(service.pi_extension_args(), ["--extension", str(extension_path)])

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

    def test_pane_git_tools_use_cached_foreground_cwd_for_every_operation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            foreground_cwd = Path(temp_dir) / "foreground" / "Sources"
            terminal_cwd = Path(temp_dir) / "terminal"
            foreground_cwd.mkdir(parents=True)
            terminal_cwd.mkdir()
            raw = snapshot_with_status()
            raw["panes"][0]["foreground_cwd"] = str(foreground_cwd)
            raw["panes"][0]["cwd"] = str(terminal_cwd)
            tools = Mock()
            tools.git_status.return_value = {
                "ok": True,
                "cwd": str(Path(temp_dir) / "foreground"),
                "branch": "feature/git-view",
                "staged": [],
                "unstaged": [{"status": "M", "file": "Sources/Pane.swift"}],
                "untracked": [],
                "commits": [{"hash": "a1b2c3d", "message": "Pane Git"}],
            }
            tools.git_diff.return_value = {
                "ok": True,
                "file": "Sources/Pane.swift",
                "section": "unstaged",
                "diff": "+change",
            }
            tools.git_stage.return_value = {"ok": True, "file": "Sources/Pane.swift"}
            tools.git_unstage.return_value = {"ok": True, "file": "Sources/Pane.swift"}
            tools.git_commit_files.return_value = {
                "ok": True,
                "hash": "a1b2c3d",
                "files": [{"status": "M", "file": "Sources/Pane.swift"}],
            }
            tools.git_commit_diff.return_value = {
                "ok": True,
                "hash": "a1b2c3d",
                "file": "Sources/Pane.swift",
                "diff": "+historical",
            }
            service = HerdrService(FakeClient([raw]), environ={}, tools=tools)
            service.refresh_snapshot()

            status = service.pane_git_status("w1:p1")
            diff = service.pane_git_diff(
                "w1:p1",
                file="Sources/Pane.swift",
                section="unstaged",
                expected_root=str((Path(temp_dir) / "foreground").resolve()),
            )
            expected_root = str((Path(temp_dir) / "foreground").resolve())
            service.pane_git_stage(
                "w1:p1",
                file="Sources/Pane.swift",
                expected_root=expected_root,
            )
            service.pane_git_unstage(
                "w1:p1",
                file="Sources/Pane.swift",
                expected_root=expected_root,
            )
            files = service.pane_git_commit_files(
                "w1:p1",
                commit_hash="a1b2c3d",
                expected_root=expected_root,
            )
            historical = service.pane_git_commit_diff(
                "w1:p1",
                commit_hash="a1b2c3d",
                file="Sources/Pane.swift",
                expected_root=expected_root,
            )

            root = foreground_cwd.resolve()
            tools.git_status.assert_called_once_with(root)
            tools.git_diff.assert_called_once_with(
                root,
                "Sources/Pane.swift",
                "unstaged",
                expected_root=expected_root,
            )
            tools.git_stage.assert_called_once_with(
                root,
                "Sources/Pane.swift",
                expected_root=expected_root,
            )
            tools.git_unstage.assert_called_once_with(
                root,
                "Sources/Pane.swift",
                expected_root=expected_root,
            )
            tools.git_commit_files.assert_called_once_with(
                root,
                "a1b2c3d",
                expected_root=expected_root,
            )
            tools.git_commit_diff.assert_called_once_with(
                root,
                "a1b2c3d",
                "Sources/Pane.swift",
                expected_root=expected_root,
            )
            self.assertEqual(status["pane_id"], "w1:p1")
            self.assertEqual(status["branch"], "feature/git-view")
            self.assertEqual(diff["diff"], "+change")
            self.assertEqual(files["files"][0]["status"], "M")
            self.assertEqual(historical["diff"], "+historical")

    def test_pane_git_context_falls_back_to_cwd_and_rejects_unknown_panes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            terminal_cwd = Path(temp_dir) / "terminal"
            terminal_cwd.mkdir()
            raw = snapshot_with_status()
            raw["panes"][0]["foreground_cwd"] = str(Path(temp_dir) / "missing")
            raw["panes"][0]["cwd"] = str(terminal_cwd)
            tools = Mock()
            tools.git_status.return_value = {
                "ok": True,
                "cwd": str(terminal_cwd),
                "branch": "main",
                "staged": [],
                "unstaged": [],
                "untracked": [],
                "commits": [],
            }
            service = HerdrService(FakeClient([raw]), environ={}, tools=tools)
            service.refresh_snapshot()

            service.pane_git_status("w1:p1")

            tools.git_status.assert_called_once_with(terminal_cwd.resolve())
            with self.assertRaises(workspace_tools.WorkspaceToolError) as context:
                service.pane_git_status("w1:missing")
            self.assertEqual(context.exception.code, "pane_not_found")
            self.assertEqual(context.exception.status, 404)

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

    def test_done_acknowledgement_survives_alert_store_restart(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "alerts.json"
            first_service = HerdrService(
                FakeClient(
                    [snapshot_with_status("working"), snapshot_with_status("done")]
                ),
                alerts=AlertStore(store_path=store_path),
                push=FakePush(),
                environ={},
            )

            first_service.refresh_snapshot()
            first_service.refresh_snapshot()
            first_service.mark_pane_alerts_read("w1:p1")

            self.assertEqual(
                first_service.workspaces_response()["workspaces"][0]["panes"][0][
                    "agent_status"
                ],
                "idle",
            )
            self.assertEqual(
                json.loads(store_path.read_text(encoding="utf-8"))["ackedDonePanes"],
                ["w1:p1"],
            )

            restarted_service = HerdrService(
                FakeClient([snapshot_with_status("done")]),
                alerts=AlertStore(store_path=store_path),
                push=FakePush(),
                environ={},
            )
            restarted_service.refresh_snapshot()

            self.assertIn("w1:p1", restarted_service.alerts.acked_done_panes())
            self.assertEqual(
                restarted_service.workspaces_response()["workspaces"][0]["panes"][0][
                    "agent_status"
                ],
                "idle",
            )

    def test_restored_done_acknowledgement_rearms_on_a_real_transition(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "alerts.json"
            first_service = HerdrService(
                FakeClient(
                    [snapshot_with_status("working"), snapshot_with_status("done")]
                ),
                alerts=AlertStore(store_path=store_path),
                push=FakePush(),
                environ={},
            )

            first_service.refresh_snapshot()
            first_service.refresh_snapshot()
            first_service.mark_pane_alerts_read("w1:p1")

            restarted_service = HerdrService(
                FakeClient(
                    [
                        snapshot_with_status("done"),
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

            self.assertNotIn("w1:p1", restarted_service.alerts.acked_done_panes())
            self.assertEqual(
                restarted_service.workspaces_response()["workspaces"][0]["panes"][0][
                    "agent_status"
                ],
                "done",
            )
            self.assertGreaterEqual(restarted_service.alerts.unread_count(), 1)

    def test_alert_store_defensively_loads_acknowledged_panes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "alerts.json"
            store_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "alerts": [],
                        "statusByPane": {"w1:p1": "done", "w1:p2": "working"},
                        "ackedDonePanes": ["w1:p1", "w1:p2", "", 17, {"bad": True}],
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                AlertStore(store_path=store_path).acked_done_panes(),
                frozenset({"w1:p1"}),
            )

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

    def test_star_store_persists_starred_panes_across_service_restart(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "stars.json"
            first_service = HerdrService(
                FakeClient([snapshot_with_status("working")]),
                stars=StarStore(store_path=store_path),
                environ={},
            )
            first_service.refresh_snapshot()

            result = first_service.set_pane_star("w1:p1", True)

            self.assertTrue(result["ok"])
            self.assertEqual(stat.S_IMODE(store_path.stat().st_mode), 0o600)
            persisted = json.loads(store_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["version"], 1)
            self.assertIsInstance(persisted["starred"], dict)
            self.assertIsInstance(persisted["starred"]["w1:p1"], str)

            second_service = HerdrService(
                FakeClient([snapshot_with_status("working")]),
                stars=StarStore(store_path=store_path),
                environ={},
            )
            self.assertEqual(second_service.stars.list(), ["w1:p1"])

    def test_setting_pane_star_publishes_once_and_idempotent_reset_publishes_nothing(self):
        service = HerdrService(FakeClient([snapshot_with_status("working")]), environ={})
        service.refresh_snapshot()
        before = service.broker.latest_id

        service.set_pane_star("w1:p1", True)

        self.assertEqual(
            sum(item["event"] == "stars.changed" for item in service.broker.after(before)),
            1,
        )
        before_second_set = service.broker.latest_id

        service.set_pane_star("w1:p1", True)

        self.assertEqual(service.broker.after(before_second_set), [])

    def test_refresh_snapshot_prunes_dead_starred_pane_and_publishes_change(self):
        missing_pane = snapshot_with_status("working")
        missing_pane["panes"] = []
        missing_pane["agents"] = []
        missing_pane["workspaces"][0]["pane_count"] = 0
        missing_pane["tabs"][0]["pane_count"] = 0
        service = HerdrService(
            FakeClient([snapshot_with_status("working"), missing_pane]),
            environ={},
        )
        service.refresh_snapshot()
        service.set_pane_star("w1:p1", True)
        self.assertEqual(service.stars.list(), ["w1:p1"])
        before = service.broker.latest_id

        service.refresh_snapshot()

        self.assertEqual(service.stars.list(), [])
        self.assertTrue(
            any(item["event"] == "stars.changed" for item in service.broker.after(before))
        )

    def test_star_store_defensively_loads_malformed_and_oversized_payloads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store_path = Path(temp_dir) / "stars.json"
            store_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "starred": {
                            "invalid": 42,
                            **{
                                f"w1:p{index}": f"2026-08-20T00:00:{index:02d}Z"
                                for index in range(12)
                            },
                        },
                        "junk": True,
                    }
                ),
                encoding="utf-8",
            )
            store_path.chmod(0o644)

            store = StarStore(maximum=10, store_path=store_path)

            self.assertEqual(store.list(), [f"w1:p{index}" for index in range(10)])
            self.assertEqual(stat.S_IMODE(store_path.stat().st_mode), 0o600)

            store_path.write_bytes(b"x" * (StarStore.MAX_STORE_BYTES + 1))
            oversized = StarStore(store_path=store_path)
            self.assertEqual(oversized.list(), [])

            store_path.write_text("{not-json", encoding="utf-8")
            malformed = StarStore(store_path=store_path)
            self.assertEqual(malformed.list(), [])

    def test_workspaces_response_includes_starred_pane_ids(self):
        service = HerdrService(FakeClient([snapshot_with_status("working")]), environ={})
        service.refresh_snapshot()
        service.set_pane_star("w1:p1", True)

        response = service.workspaces_response()

        self.assertEqual(response["starredPaneIds"], ["w1:p1"])

    def test_snapshot_refresh_change_detection_and_force_publish(self):
        first = snapshot_with_status()
        volatile_only = copy.deepcopy(first)
        volatile_only["generated_at"] = "later"
        revised = copy.deepcopy(first)
        revised["panes"][0]["revision"] = 11
        service = HerdrService(FakeClient([first, volatile_only, revised, revised]), environ={})

        service.refresh_snapshot()
        service.refresh_snapshot()
        service.refresh_snapshot()
        service.refresh_snapshot(force=True)

        updates = [item for item in service.broker.after(0) if item["event"] == "snapshot.updated"]
        self.assertEqual(len(updates), 3)
        self.assertEqual(updates[1]["data"]["paneRevisions"], {"w1:p1": 11})

    def test_identical_snapshot_after_request_recovery_publishes_herd_pulse(self):
        snapshot = snapshot_with_status()
        push = FakePush()
        client = FakeClient([snapshot, snapshot])
        service = HerdrService(client, push=push, environ={})

        service.refresh_snapshot()
        client.fail = True
        with self.assertRaises(HerdrClientError):
            service.refresh_snapshot()
        pulse_count_after_failure = len(push.pulses)
        client.fail = False
        service.refresh_snapshot()

        self.assertEqual(len(push.pulses), pulse_count_after_failure + 1)

    def test_identical_snapshot_without_recovery_does_not_publish_herd_pulse(self):
        snapshot = snapshot_with_status()
        push = FakePush()
        service = HerdrService(FakeClient([snapshot, snapshot]), push=push, environ={})

        service.refresh_snapshot()
        service.refresh_snapshot()

        self.assertEqual(len(push.pulses), 1)

    def test_mutation_with_an_identical_snapshot_does_not_duplicate_refresh_event(self):
        snapshot = snapshot_with_status()
        service = HerdrService(FakeClient([snapshot, snapshot]), environ={})

        service.refresh_snapshot()
        service.invoke("pane.focus", {"pane_id": "w1:p1"})

        updates = [item for item in service.broker.after(0) if item["event"] == "snapshot.updated"]
        self.assertEqual(len(updates), 1)

    def test_refresh_loop_coalesces_a_burst_on_the_trailing_edge(self):
        service = HerdrService(FakeClient([snapshot_with_status()]), environ={})
        thread = threading.Thread(target=service._refresh_loop, daemon=True)
        thread.start()
        try:
            for _ in range(20):
                service._handle_event({"event": "pane.focused", "data": {"pane_id": "w1:p1"}})
                time.sleep(0.004)
            deadline = time.monotonic() + 1.2
            while time.monotonic() < deadline:
                updates = [item for item in service.broker.after(0) if item["event"] == "snapshot.updated"]
                if updates:
                    break
                time.sleep(0.01)
            self.assertEqual(len(updates), 1)
        finally:
            service._stop_event.set()
            service._refresh_event.set()
            thread.join(timeout=1.0)

    def test_global_pi_broker_filters_high_frequency_events(self):
        service = HerdrService(FakeClient([snapshot_with_status()]), environ={})

        service._publish_pi_event({"event": {"type": "message_update"}})
        service._publish_pi_event({"event": {"type": "bridge.connection", "connected": True}})

        events = service.broker.after(0)
        self.assertEqual([item["event"] for item in events], ["pi.bridge.connection"])

    def test_pi_capability_uses_scalar_journal_state_without_snapshot_load(self):
        journal = PiSemanticJournal(":memory:")
        manager = PiSemanticManager("/tmp/capability.sock", environ={}, journal=journal)
        manager.sync_snapshot({"panes": [{"pane_id": "w1:p1", "agent": "pi"}], "agents": []})
        journal.ingest(
            "w1:p1",
            {
                "protocol": PI_SEMANTIC_PROTOCOL,
                "pane_id": "w1:p1",
                "kind": "snapshot",
                "snapshot": {"session": {"id": "session-1"}, "entries": [{"id": "entry-1"}]},
            },
            namespace=manager.namespace,
        )
        with patch.object(journal, "snapshot", side_effect=AssertionError("capability must not load transcript")):
            capability = manager.capability("w1:p1")
        self.assertTrue(capability["available"])
        self.assertEqual(capability["session_id"], "session-1")
        self.assertEqual(capability["cursor"], 0)
        self.assertEqual(capability["oldest_cursor"], 1)
        manager.close()

    def test_pi_capability_lazily_backfills_legacy_scalar_columns(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "legacy.sqlite3")
            database = sqlite3.connect(path)
            database.execute(
                "CREATE TABLE pi_semantic_state (pane_id TEXT PRIMARY KEY, instance_id TEXT, "
                "source_sequence INTEGER NOT NULL DEFAULT 0, session_id TEXT, snapshot_json TEXT, "
                "snapshot_cursor INTEGER NOT NULL DEFAULT 0, connected INTEGER NOT NULL DEFAULT 0, "
                "updated_at TEXT NOT NULL)"
            )
            database.commit()
            database.close()
            journal = PiSemanticJournal(path)
            manager = PiSemanticManager("/tmp/legacy-capability.sock", environ={}, journal=journal)
            manager.sync_snapshot({"panes": [{"pane_id": "w1:p1", "agent": "pi"}], "agents": []})
            storage_pane_id = journal._storage_pane_id("w1:p1", manager.namespace)
            with journal._database:
                journal._database.execute(
                    "INSERT INTO pi_semantic_state (pane_id, snapshot_json, updated_at) VALUES (?, ?, ?)",
                    (storage_pane_id, json.dumps({"session": {"id": "legacy-session"}, "entries": [{"id": "entry-1"}]}), "now"),
                )

            capability = manager.capability("w1:p1")
            backfilled = journal._database.execute(
                "SELECT session_id, has_content FROM pi_semantic_state WHERE pane_id = ?",
                (storage_pane_id,),
            ).fetchone()
            self.assertEqual(capability["session_id"], "legacy-session")
            self.assertTrue(capability["available"])
            self.assertEqual(backfilled["session_id"], "legacy-session")
            self.assertEqual(backfilled["has_content"], 1)
            manager.close()

    def test_pi_capability_backfill_does_not_repeat_for_sessionless_pane(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "legacy.sqlite3")
            database = sqlite3.connect(path)
            database.execute(
                "CREATE TABLE pi_semantic_state (pane_id TEXT PRIMARY KEY, instance_id TEXT, "
                "source_sequence INTEGER NOT NULL DEFAULT 0, session_id TEXT, snapshot_json TEXT, "
                "snapshot_cursor INTEGER NOT NULL DEFAULT 0, connected INTEGER NOT NULL DEFAULT 0, "
                "updated_at TEXT NOT NULL)"
            )
            database.commit()
            database.close()
            journal = PiSemanticJournal(path)
            manager = PiSemanticManager("/tmp/legacy-sessionless-capability.sock", environ={}, journal=journal)
            manager.sync_snapshot({"panes": [{"pane_id": "w1:p1", "agent": "pi"}], "agents": []})
            storage_pane_id = journal._storage_pane_id("w1:p1", manager.namespace)
            with journal._database:
                journal._database.execute(
                    "INSERT INTO pi_semantic_state (pane_id, snapshot_json, updated_at) VALUES (?, ?, ?)",
                    (storage_pane_id, json.dumps({"entries": [{"id": "entry-1"}]}), "now"),
                )

            first = manager.capability("w1:p1")
            with patch("herdr_harness.pi_semantic.json.loads", side_effect=AssertionError("backfill repeated")):
                second = manager.capability("w1:p1")

            self.assertTrue(first["available"])
            self.assertIsNone(first["session_id"])
            self.assertTrue(second["available"])
            self.assertIsNone(second["session_id"])
            manager.close()

    def test_pi_journal_retention_scans_only_when_needed(self):
        journal = PiSemanticJournal(":memory:", maximum_events_per_pane=64)
        for sequence in range(1, 115):
            journal.ingest(
                "w1:p1",
                {
                    "protocol": PI_SEMANTIC_PROTOCOL,
                    "pane_id": "w1:p1",
                    "kind": "event",
                    "sequence": sequence,
                    "instance_id": "test",
                    "event": {"type": "message_update", "text": str(sequence)},
                },
            )
        retained = journal.events_after("w1:p1", 0, limit=128)
        self.assertLessEqual(len(retained), 64)
        self.assertLess(journal._trim_scan_count, 114)
        journal.close()

    def test_terminal_observer_reassembles_large_frames_and_drains_stderr(self):
        with tempfile.TemporaryDirectory() as temporary:
            observer_script = Path(temporary) / "observer.py"
            observer_script.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "sys.stderr.write('e' * 70000)\n"
                "sys.stderr.flush()\n"
                "sys.stdout.write(json.dumps({'event': 'terminal.frame', 'payload': 'x' * 200000}) + '\\n')\n"
                "sys.stdout.flush()\n",
                encoding="utf-8",
            )
            observer_script.chmod(0o700)
            observer = TerminalObserver(
                "w1:p1",
                cols=80,
                rows=24,
                socket_path="/tmp/herdr.sock",
                session="test",
                environ={"HERDR_BIN_PATH": str(observer_script)},
            )
            frames = list(observer.frames())

        records = [frame for frame in frames if frame["event"] == "terminal.frame"]
        self.assertEqual(len(records), 1)
        self.assertEqual(len(records[0]["data"]["payload"]), 200000)
        self.assertEqual(
            inspect.signature(TerminalObserver.frames).parameters["heartbeat_seconds"].default,
            2.0,
        )

    def test_terminal_observer_surfaces_final_unterminated_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            observer_script = Path(temporary) / "observer.py"
            observer_script.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "sys.stdout.write(json.dumps({'event': 'terminal.frame', 'payload': 'last'}))\n"
                "sys.stdout.flush()\n",
                encoding="utf-8",
            )
            observer_script.chmod(0o700)
            observer = TerminalObserver(
                "w1:p1", cols=80, rows=24, socket_path="/tmp/herdr.sock", session="test",
                environ={"HERDR_BIN_PATH": str(observer_script)},
            )
            frames = list(observer.frames())

        self.assertTrue(any(frame["event"] == "terminal.frame" for frame in frames))


if __name__ == "__main__":
    unittest.main()
