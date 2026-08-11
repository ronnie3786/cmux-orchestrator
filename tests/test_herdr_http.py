import http.client
import json
import threading
import unittest
import urllib.error
import urllib.request

from herdr_harness.events import EventBroker
from herdr_harness.server import make_server


class FakeHTTPService:
    def __init__(self):
        self.environ = {}
        self.broker = EventBroker()
        self.calls = []
        self.snapshot = {
            "version": "0.8.0",
            "protocol": 19,
            "workspaces": [{"workspace_id": "w1", "label": "Feature Lab", "future": True}],
            "tabs": [],
            "panes": [],
            "agents": [],
            "layouts": [],
        }

    def health_response(self):
        return {
            "ok": True,
            "herdr": {"connected": True},
            "cache": {"available": True},
        }

    def network_response(self, port, host_header=""):
        return {"ok": True, "port": port, "requested": host_header}

    def snapshot_response(self):
        return {"ok": True, "snapshot": self.snapshot, "generatedAt": "2026-08-11T00:00:00Z"}

    def workspaces_response(self):
        workspace = dict(self.snapshot["workspaces"][0])
        workspace.update({"tabs": [], "panes": [], "agents": [], "layouts": []})
        return {"ok": True, "workspaces": [workspace], "alerts": [], "generatedAt": "now"}

    def workspace_response(self, workspace_id):
        if workspace_id != "w1":
            return None
        return {"ok": True, "workspace": self.workspaces_response()["workspaces"][0], "alerts": [], "generatedAt": "now"}

    def invoke(self, method, params):
        self.calls.append((method, params))
        return {"ok": True, "result": {"type": "ok", "method": method}}

    def read_pane(self, pane_id, **options):
        self.calls.append(("pane.read", {"pane_id": pane_id, **options}))
        return {"ok": True, "output": {"pane_id": pane_id, "text": "hello", "future": 1}, "result": {}}

    def list_alerts(self, **_options):
        return {"ok": True, "alerts": [{"id": "alert_1", "isRead": False}], "unreadCount": 1}

    def mark_alert_read(self, alert_id):
        if alert_id != "alert_1":
            return None
        return {"ok": True, "alert": {"id": alert_id, "isRead": True}, "unreadCount": 0}

    def mark_all_alerts_read(self):
        return {"ok": True, "alerts": [], "unreadCount": 0}

    def push_status(self):
        return {"ok": True, "apns": {"configured": False, "deviceCount": 0}}

    def register_push_device(self, device_token, *, bundle_id, environment):
        self.calls.append(
            (
                "push.register",
                {"deviceToken": device_token, "bundleId": bundle_id, "environment": environment},
            )
        )
        return {"ok": True, "registered": True, "deviceCount": 1}

    def unregister_push_device(self, device_token):
        self.calls.append(("push.unregister", {"deviceToken": device_token}))
        return {"ok": True, "unregistered": True, "deviceCount": 0}


class HerdrHTTPTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeHTTPService()
        self.server = make_server(self.service, host="127.0.0.1", port=0, api_token="test-secret")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)

    def request(self, path, *, method="GET", payload=None, token="test-secret"):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, response.headers, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers, json.loads(exc.read())

    def test_setup_page_is_public_but_api_requires_bearer_token(self):
        with urllib.request.urlopen(self.base + "/", timeout=2) as response:
            html = response.read().decode()
        status, headers, body = self.request("/api/v1/health", token=None)

        self.assertIn("Your agents, within reach", html)
        self.assertIn("--https=8461", html)
        self.assertNotIn("localStorage", html)
        self.assertEqual(status, 401)
        self.assertEqual(headers["WWW-Authenticate"], 'Bearer realm="Herdr Harness"')
        self.assertEqual(body["error"]["code"], "unauthorized")

    def test_api_prefix_requires_exact_version_segment(self):
        for path in ("/api/v10/workspaces", "/api/v1evil/workspaces"):
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 404)
                self.assertEqual(body["error"]["code"], "not_found")

    def test_snapshot_and_workspace_contracts_keep_native_fields(self):
        snapshot_status, _, snapshot = self.request("/api/v1/snapshot")
        workspaces_status, _, workspaces = self.request("/api/v1/workspaces")

        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["snapshot"]["workspaces"][0]["future"], True)
        self.assertEqual(workspaces_status, 200)
        self.assertEqual(workspaces["workspaces"][0]["workspace_id"], "w1")
        self.assertEqual(workspaces["workspaces"][0]["tabs"], [])
        self.assertIn("alerts", workspaces)

    def test_workspace_create_validates_and_forwards_native_params(self):
        status, _, body = self.request(
            "/api/v1/workspaces",
            method="POST",
            payload={"label": "New Work", "cwd": "/tmp", "focus": False, "env": {"DEMO": "1"}},
        )

        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(
            self.service.calls[-1],
            (
                "workspace.create",
                {"focus": False, "env": {"DEMO": "1"}, "cwd": "/tmp", "label": "New Work"},
            ),
        )

    def test_relative_cwd_and_invalid_keys_are_rejected(self):
        cwd_status, _, cwd_body = self.request(
            "/api/v1/workspaces",
            method="POST",
            payload={"cwd": "relative/path"},
        )
        keys_status, _, keys_body = self.request(
            "/api/v1/panes/w1:p1/send-keys",
            method="POST",
            payload={"keys": ["ctrl+c; rm"]},
        )

        self.assertEqual(cwd_status, 400)
        self.assertIn("absolute", cwd_body["error"]["message"])
        self.assertEqual(keys_status, 400)
        self.assertEqual(keys_body["error"]["code"], "invalid_request")
        self.assertEqual(self.service.calls, [])

    def test_pane_actions_use_agent_aware_and_atomic_herdr_methods(self):
        cases = [
            ("/api/v1/panes/w1:p1/run", {"command": "swift test"}, "pane.send_input"),
            ("/api/v1/panes/w1:p1/prompt", {"text": "Continue", "wait": True}, "agent.prompt"),
            (
                "/api/v1/panes/w1:p1/start-agent",
                {"name": "reviewer", "kind": "codex", "args": []},
                "agent.start",
            ),
        ]
        for path, payload, expected_method in cases:
            with self.subTest(path=path):
                status, _, _ = self.request(path, method="POST", payload=payload)
                self.assertEqual(status, 200)
                self.assertEqual(self.service.calls[-1][0], expected_method)

        self.assertEqual(
            self.service.calls[0][1],
            {"pane_id": "w1:p1", "text": "swift test", "keys": ["enter"]},
        )
        self.assertEqual(self.service.calls[1][1]["target"], "w1:p1")
        self.assertEqual(self.service.calls[1][1]["wait"]["timeout_ms"], 120000)

    def test_output_route_normalizes_recent_unwrapped_source(self):
        status, _, body = self.request(
            "/api/v1/panes/w1:p1/output?source=recent-unwrapped&lines=80&stripAnsi=true"
        )

        self.assertEqual(status, 200)
        self.assertEqual(body["output"]["future"], 1)
        self.assertEqual(self.service.calls[-1][1]["source"], "recent_unwrapped")
        self.assertEqual(self.service.calls[-1][1]["lines"], 80)

    def test_alert_list_and_read_routes(self):
        list_status, _, listed = self.request("/api/v1/alerts?unread=true")
        read_status, _, read = self.request(
            "/api/v1/alerts/alert_1/read",
            method="POST",
            payload={},
        )

        self.assertEqual(list_status, 200)
        self.assertEqual(listed["unreadCount"], 1)
        self.assertEqual(read_status, 200)
        self.assertTrue(read["alert"]["isRead"])

    def test_sse_route_is_authenticated_and_sends_ready_frame(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=2)
        connection.request(
            "GET",
            "/api/v1/events?once=true",
            headers={"Authorization": "Bearer test-secret"},
        )
        response = connection.getresponse()
        payload = response.read().decode()
        connection.close()

        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream; charset=utf-8")
        self.assertIn("event: ready", payload)
        self.assertIn("retry: 1000", payload)

    def test_sse_high_resume_id_emits_restart_reset_instead_of_stalling(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=2)
        connection.request(
            "GET",
            "/api/v1/events?once=true&after=999999",
            headers={"Authorization": "Bearer test-secret"},
        )
        response = connection.getresponse()
        payload = response.read().decode()
        connection.close()

        self.assertEqual(response.status, 200)
        self.assertIn("event: stream.reset", payload)
        self.assertIn("backend_restarted", payload)

    def test_push_registration_and_unregistration_are_bearer_protected(self):
        token = "ab" * 32
        unauthorized, _, _ = self.request(
            "/api/v1/push/devices",
            method="POST",
            payload={"deviceToken": token, "bundleId": "com.example.App"},
            token=None,
        )
        registered, _, body = self.request(
            "/api/v1/push/devices",
            method="POST",
            payload={
                "deviceToken": token,
                "bundleId": "com.example.App",
                "environment": "sandbox",
            },
        )
        unregistered, _, _ = self.request(
            "/api/v1/push/unregister",
            method="POST",
            payload={"deviceToken": token},
        )

        self.assertEqual(unauthorized, 401)
        self.assertEqual(registered, 200)
        self.assertTrue(body["registered"])
        self.assertEqual(unregistered, 200)
        self.assertEqual(self.service.calls[-2][0], "push.register")
        self.assertEqual(self.service.calls[-1][0], "push.unregister")

    def test_push_registration_requires_server_token_even_in_open_dev_mode(self):
        open_server = make_server(self.service, host="127.0.0.1", port=0, api_token="")
        open_thread = threading.Thread(target=open_server.serve_forever, daemon=True)
        open_thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{open_server.server_address[1]}/api/v1/push/devices",
                method="POST",
                data=json.dumps({"deviceToken": "ab" * 32}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with self.assertRaises(urllib.error.HTTPError) as context:
                urllib.request.urlopen(request, timeout=2)
            body = json.loads(context.exception.read())
        finally:
            open_server.shutdown()
            open_server.server_close()
            open_thread.join(timeout=1)

        self.assertEqual(context.exception.code, 503)
        self.assertEqual(body["error"]["code"], "api_token_required")


if __name__ == "__main__":
    unittest.main()
