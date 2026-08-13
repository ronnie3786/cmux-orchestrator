import http.client
import json
import threading
import unittest
import urllib.error
import urllib.request

from herdr_harness.events import EventBroker
from herdr_harness.server import make_server
from herdr_harness.workspace_tools import WorkspaceToolError


class FakePiSemantic:
    def bounds(self, _pane_id):
        return (1, 2)

    def wait_after(self, _pane_id, _cursor, timeout=15.0):
        return []


class FakeHTTPService:
    def __init__(self):
        self.environ = {}
        self.broker = EventBroker()
        self.pi_semantic = FakePiSemantic()
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

    def workspace_git_status(self, workspace_id):
        self.calls.append(("workspace.git", {"workspace_id": workspace_id}))
        return {
            "ok": True,
            "workspace_id": workspace_id,
            "root_path": "/server/resolved/repo",
            "branch": "feature/panes",
            "staged": [],
            "unstaged": [{"status": "M", "file": "Pane.swift"}],
            "untracked": ["NewPane.swift"],
            "commits": [],
        }

    def workspace_git_diff(self, workspace_id, *, file, section):
        if file.startswith("/") or ".." in file.split("/"):
            raise WorkspaceToolError("file must stay inside the repository", code="invalid_git_path", status=400)
        self.calls.append(("workspace.git.diff", {"workspace_id": workspace_id, "file": file, "section": section}))
        return {"ok": True, "workspace_id": workspace_id, "file": file, "section": section, "diff": "+change", "truncated": False}

    def workspace_git_stage(self, workspace_id, *, file):
        self.calls.append(("workspace.git.stage", {"workspace_id": workspace_id, "file": file}))
        return {"ok": True, "workspace_id": workspace_id, "file": file}

    def workspace_git_unstage(self, workspace_id, *, file):
        self.calls.append(("workspace.git.unstage", {"workspace_id": workspace_id, "file": file}))
        return {"ok": True, "workspace_id": workspace_id, "file": file}

    def workspace_skills(self, workspace_id):
        self.calls.append(("workspace.skills", {"workspace_id": workspace_id}))
        return {"ok": True, "workspace_id": workspace_id, "root_path": "/server/resolved/repo", "project_skills": [], "user_skills": [], "skills": []}

    def workspace_file_search(self, workspace_id, *, query, limit):
        self.calls.append(("workspace.files", {"workspace_id": workspace_id, "query": query, "limit": limit}))
        return {"ok": True, "workspace_id": workspace_id, "root_path": "/server/resolved/repo", "query": query, "files": [{"path": "Sources/Pane.swift"}], "truncated": False, "limit": limit}

    def workspace_attachment(self, workspace_id, *, filename, content_type, data_base64):
        self.calls.append(("workspace.attachment", {"workspace_id": workspace_id, "filename": filename, "content_type": content_type, "data_base64": data_base64}))
        return {"ok": True, "attachment": {"workspace_id": workspace_id, "original_filename": filename, "content_type": content_type}}

    def jira_assigned(self, *, project, limit):
        self.calls.append(("jira.assigned", {"project": project, "limit": limit}))
        return {"ok": True, "project": project or None, "projects": [], "site": "jira.example.test", "tickets": []}

    def jira_issue(self, *, query):
        self.calls.append(("jira.issue", {"query": query}))
        return {"ok": True, "site": "jira.example.test", "ticket": {"key": "HERD-1"}}

    def invoke(self, method, params):
        self.calls.append((method, params))
        return {"ok": True, "result": {"type": "ok", "method": method}}

    def read_pane(self, pane_id, **options):
        self.calls.append(("pane.read", {"pane_id": pane_id, **options}))
        return {"ok": True, "output": {"pane_id": pane_id, "text": "hello", "future": 1}, "result": {}}

    def pi_snapshot_response(self, pane_id):
        self.calls.append(("pi.snapshot", {"pane_id": pane_id}))
        return {
            "ok": True,
            "protocol": {"name": "herdr.pi.semantic", "version": 1},
            "pane_id": pane_id,
            "available": True,
            "connected": False,
            "session": {"id": "pi-session"},
            "state": {"idle": True},
            "entries": [{"id": "entry-1", "parentId": None}],
            "pending_interactions": [],
            "cursor": 2,
            "oldest_cursor": 1,
            "truncated": False,
            "generated_at": "now",
        }

    def pi_command(self, pane_id, command, payload=None):
        self.calls.append((f"pi.{command}", {"pane_id": pane_id, "payload": payload or {}}))
        return {"ok": True, "success": True, "result": {"accepted": True}}

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

    def register_live_activity(self, push_token, *, activity_id, bundle_id, environment):
        self.calls.append(
            (
                "live_activity.register",
                {
                    "pushToken": push_token,
                    "activityId": activity_id,
                    "bundleId": bundle_id,
                    "environment": environment,
                },
            )
        )
        return {"ok": True, "registered": True, "liveActivityCount": 1}

    def unregister_live_activity(self, activity_id, *, push_token=None):
        self.calls.append(
            (
                "live_activity.unregister",
                {"activityId": activity_id, "pushToken": push_token},
            )
        )
        return {"ok": True, "unregistered": True, "liveActivityCount": 0}


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

    def test_workspace_tool_routes_use_workspace_id_and_snake_case_contracts(self):
        git_status, _, git_body = self.request("/api/v1/workspaces/w1/git?path=/client/cannot/choose")
        diff_status, _, diff_body = self.request(
            "/api/v1/workspaces/w1/git/diff?file=Sources%2FPane.swift&section=staged"
        )
        stage_status, _, _ = self.request(
            "/api/v1/workspaces/w1/git/stage",
            method="POST",
            payload={"file": "Sources/Pane.swift"},
        )
        skills_status, _, skills_body = self.request("/api/v1/workspaces/w1/skills")
        files_status, _, files_body = self.request("/api/v1/workspaces/w1/files?q=Pane&limit=12")
        attachment_status, _, attachment_body = self.request(
            "/api/v1/workspaces/w1/attachments",
            method="POST",
            payload={"filename": "notes.txt", "content_type": "text/plain", "data_base64": "aGVsbG8="},
        )

        self.assertEqual(
            [git_status, diff_status, stage_status, skills_status, files_status, attachment_status],
            [200, 200, 200, 200, 200, 200],
        )
        self.assertEqual(git_body["root_path"], "/server/resolved/repo")
        self.assertEqual(git_body["untracked"], ["NewPane.swift"])
        self.assertEqual(diff_body["section"], "staged")
        self.assertIn("project_skills", skills_body)
        self.assertEqual(files_body["files"], [{"path": "Sources/Pane.swift"}])
        self.assertEqual(attachment_body["attachment"]["workspace_id"], "w1")
        self.assertIn(("workspace.git", {"workspace_id": "w1"}), self.service.calls)
        self.assertIn(("workspace.files", {"workspace_id": "w1", "query": "Pane", "limit": 12}), self.service.calls)

    def test_workspace_tool_routes_require_auth_and_reject_git_traversal(self):
        unauthorized, _, auth_body = self.request("/api/v1/workspaces/w1/git", token=None)
        invalid, _, invalid_body = self.request(
            "/api/v1/workspaces/w1/git/diff?file=..%2Fsecret&section=unstaged"
        )

        self.assertEqual(unauthorized, 401)
        self.assertEqual(auth_body["error"]["code"], "unauthorized")
        self.assertEqual(invalid, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_git_path")

    def test_jira_routes_validate_and_forward_queries(self):
        assigned_status, _, _ = self.request("/api/v1/jira/assigned?project=HERD&limit=9")
        issue_status, _, issue = self.request("/api/v1/jira/issue?q=https%3A%2F%2Fjira.example%2Fbrowse%2FHERD-1")

        self.assertEqual(assigned_status, 200)
        self.assertEqual(issue_status, 200)
        self.assertEqual(issue["ticket"]["key"], "HERD-1")
        self.assertIn(("jira.assigned", {"project": "HERD", "limit": 9}), self.service.calls)

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

    def test_pi_snapshot_and_command_routes_preserve_the_semantic_contract(self):
        snapshot_status, _, snapshot = self.request("/api/v1/panes/w1:p1/pi/snapshot")
        prompt_status, _, prompt = self.request(
            "/api/v1/panes/w1:p1/pi/prompt",
            method="POST",
            payload={"text": "Fix the tests"},
        )
        follow_status, _, _ = self.request(
            "/api/v1/panes/w1:p1/pi/follow-up",
            method="POST",
            payload={"text": "Then review it"},
        )
        abort_status, _, _ = self.request(
            "/api/v1/panes/w1:p1/pi/abort",
            method="POST",
            payload={},
        )

        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["protocol"], {"name": "herdr.pi.semantic", "version": 1})
        self.assertEqual(snapshot["entries"][0]["id"], "entry-1")
        self.assertFalse(snapshot["connected"])
        self.assertEqual(prompt_status, 200)
        self.assertTrue(prompt["success"])
        self.assertEqual(follow_status, 200)
        self.assertEqual(abort_status, 200)
        self.assertIn(("pi.prompt", {"pane_id": "w1:p1", "payload": {"text": "Fix the tests"}}), self.service.calls)
        self.assertIn(("pi.follow_up", {"pane_id": "w1:p1", "payload": {"text": "Then review it"}}), self.service.calls)
        self.assertIn(("pi.abort", {"pane_id": "w1:p1", "payload": {}}), self.service.calls)

    def test_pi_interaction_response_is_bounded_and_forwarded(self):
        valid_status, _, _ = self.request(
            "/api/v1/panes/w1:p1/pi/interactions/ui-1/respond",
            method="POST",
            payload={"value": "Staging", "confirmed": True},
        )
        invalid_status, _, invalid = self.request(
            "/api/v1/panes/w1:p1/pi/interactions/ui-1/respond",
            method="POST",
            payload={"raw": {"unbounded": True}},
        )

        self.assertEqual(valid_status, 200)
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid["error"]["code"], "invalid_request")
        self.assertIn(
            (
                "pi.interaction_response",
                {
                    "pane_id": "w1:p1",
                    "payload": {"interactionId": "ui-1", "value": "Staging", "confirmed": True},
                },
            ),
            self.service.calls,
        )

    def test_pi_sse_ready_reports_actual_bridge_connection_and_reset(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=2)
        connection.request(
            "GET",
            "/api/v1/panes/w1:p1/pi/events?once=true&after=99",
            headers={"Authorization": "Bearer test-secret"},
        )
        response = connection.getresponse()
        payload = response.read().decode()
        connection.close()

        self.assertEqual(response.status, 200)
        self.assertIn("event: pi.ready", payload)
        self.assertIn('"connected":false', payload)
        self.assertIn("event: pi.stream.reset", payload)
        self.assertIn("backend_restarted", payload)

    def test_pi_sse_ready_cursor_does_not_jump_past_unreplayed_events(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=2)
        connection.request(
            "GET",
            "/api/v1/panes/w1:p1/pi/events?once=true&after=1",
            headers={"Authorization": "Bearer test-secret"},
        )
        response = connection.getresponse()
        payload = response.read().decode()
        connection.close()

        self.assertEqual(response.status, 200)
        ready_data = next(line.removeprefix("data: ") for line in payload.splitlines() if line.startswith("data: "))
        ready = json.loads(ready_data)
        self.assertEqual(ready["cursor"], 1)
        self.assertEqual(ready["latest_cursor"], 2)

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

    def test_live_activity_registration_and_unregistration_are_bearer_protected(self):
        token = "ab" * 32
        unauthorized, _, _ = self.request(
            "/api/v1/live-activities",
            method="POST",
            payload={
                "activityId": "pulse-1",
                "pushToken": token,
                "bundleId": "com.example.Herdr",
            },
            token=None,
        )
        registered, _, body = self.request(
            "/api/v1/live-activities",
            method="POST",
            payload={
                "activityId": "pulse-1",
                "pushToken": token,
                "bundleId": "com.example.Herdr",
                "environment": "sandbox",
            },
        )
        unregistered, _, _ = self.request(
            "/api/v1/live-activities/unregister",
            method="POST",
            payload={"activityId": "pulse-1", "pushToken": token},
        )

        self.assertEqual(unauthorized, 401)
        self.assertEqual(registered, 200)
        self.assertTrue(body["registered"])
        self.assertEqual(unregistered, 200)
        self.assertEqual(self.service.calls[-2][0], "live_activity.register")
        self.assertEqual(self.service.calls[-1][0], "live_activity.unregister")


if __name__ == "__main__":
    unittest.main()
