import http.client
import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

from herdr_harness.events import EventBroker
from herdr_harness.pi_semantic import PiSemanticError
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService
from herdr_harness.workspace_tools import WorkspaceToolError
from tests.test_herdr_service import FakeClient, snapshot_with_status


class FakePiSemantic:
    def bounds(self, _pane_id):
        return (1, 2)

    def wait_after(self, _pane_id, _cursor, timeout=15.0):
        return []


class FakeCleanup:
    def __init__(self, calls):
        self.calls = calls

    def start_run(self, options):
        self.calls.append(("cleanup.start_run", options))
        return {"ok": True, "runId": "clr_0123456789ab", "status": "collecting"}


class FakeHTTPService:
    def __init__(self):
        self.environ = {}
        self.broker = EventBroker()
        self.pi_semantic = FakePiSemantic()
        self.pi_command_error = None
        self.pi_extension_args_calls = 0
        self.split_result = None
        self.calls = []
        self.cleanup = FakeCleanup(self.calls)
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

    def response_audio_capabilities(self):
        self.calls.append(("response_audio.capabilities", {}))
        return {"ok": True, "available": True, "listen": True, "tldr": True}

    def prepare_response_audio(self, *, action, text):
        self.calls.append(("response_audio.prepare", {"action": action, "text": text}))
        return {"ok": True, "action": action, "chunks": ["Prepared response"]}

    def synthesize_response_audio(self, *, text):
        self.calls.append(("response_audio.speech", {"text": text}))
        return {"ok": True, "audioBase64": "SUQz", "contentType": "audio/mpeg"}

    def snapshot_response(self):
        return {"ok": True, "snapshot": self.snapshot, "generatedAt": "2026-08-11T00:00:00Z"}

    def workspaces_response(self):
        workspace = dict(self.snapshot["workspaces"][0])
        workspace.update({"tabs": [], "panes": [], "agents": [], "layouts": []})
        return {
            "ok": True,
            "workspaces": [workspace],
            "alerts": [],
            "starredPaneIds": [],
            "generatedAt": "now",
        }

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

    def pane_git_status(self, pane_id):
        self.calls.append(("pane.git", {"pane_id": pane_id}))
        return {
            "ok": True,
            "pane_id": pane_id,
            "workspace_id": "w1",
            "root_path": "/server/resolved/pane-repo",
            "branch": "feature/pane-git",
            "staged": [],
            "unstaged": [{"status": "M", "file": "Sources/Pane.swift"}],
            "untracked": ["Sources/NewPane.swift"],
            "commits": [{"hash": "a1b2c3d", "message": "Pane Git"}],
        }

    def pane_git_diff(self, pane_id, *, file, section, expected_root):
        if file.startswith("/") or ".." in file.split("/"):
            raise WorkspaceToolError(
                "file must stay inside the repository",
                code="invalid_git_path",
                status=400,
            )
        self.calls.append(
            (
                "pane.git.diff",
                {
                    "pane_id": pane_id,
                    "file": file,
                    "section": section,
                    "expected_root": expected_root,
                },
            )
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "file": file,
            "section": section,
            "diff": "+change",
            "truncated": False,
        }

    def pane_git_stage(self, pane_id, *, file, expected_root):
        self.calls.append((
            "pane.git.stage",
            {"pane_id": pane_id, "file": file, "expected_root": expected_root},
        ))
        return {"ok": True, "pane_id": pane_id, "file": file}

    def pane_git_unstage(self, pane_id, *, file, expected_root):
        self.calls.append((
            "pane.git.unstage",
            {"pane_id": pane_id, "file": file, "expected_root": expected_root},
        ))
        return {"ok": True, "pane_id": pane_id, "file": file}

    def pane_git_commit_files(self, pane_id, *, commit_hash, expected_root):
        self.calls.append(
            (
                "pane.git.commit-files",
                {
                    "pane_id": pane_id,
                    "hash": commit_hash,
                    "expected_root": expected_root,
                },
            )
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "hash": commit_hash,
            "files": [{"status": "M", "file": "Sources/Pane.swift"}],
        }

    def pane_git_commit_diff(self, pane_id, *, commit_hash, file, expected_root):
        self.calls.append(
            (
                "pane.git.commit-diff",
                {
                    "pane_id": pane_id,
                    "hash": commit_hash,
                    "file": file,
                    "expected_root": expected_root,
                },
            )
        )
        return {
            "ok": True,
            "pane_id": pane_id,
            "hash": commit_hash,
            "file": file,
            "diff": "+historical",
            "truncated": False,
        }

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
        if method == "pane.split" and self.split_result is not None:
            return {"ok": True, "result": self.split_result}
        if method == "pane.rename":
            tab_id = None
            for pane in self.snapshot.get("panes", []):
                if pane.get("pane_id") == params.get("pane_id"):
                    tab_id = pane.get("tab_id")
                    break
            return {
                "ok": True,
                "result": {
                    "type": "pane_info",
                    "pane": {"pane_id": params.get("pane_id"), "tab_id": tab_id, "label": params.get("label")},
                },
            }
        return {"ok": True, "result": {"type": "ok", "method": method}}

    def pi_extension_args(self):
        self.pi_extension_args_calls += 1
        return ["--extension", "/fake/bridge"]

    def quick_pi_session(
        self,
        label,
        *,
        workspace_id=None,
        tab_id=None,
        cwd=None,
        session_file=None,
        session_id=None,
        request_id=None,
        **extra,
    ):
        self.calls.append(
            (
                "quick_pi_session",
                {
                    "label": label,
                    "workspace_id": workspace_id,
                    "tab_id": tab_id,
                    "cwd": cwd,
                    "session_file": session_file,
                    "session_id": session_id,
                    "request_id": request_id,
                    **extra,
                },
            )
        )
        return {
            "ok": True,
            "workspace_id": "w1",
            "tab_id": "w1:t1",
            "pane_id": "w1:p1",
            "created_workspace": True,
            "created_tab": True,
            "created_pane": True,
            "pi_extension_attached": True,
            "pi_semantic_ready": session_id is not None,
            "request_id": request_id,
            "session_id": session_id,
        }

    @staticmethod
    def _agent_run(status="completed", *, mode="ask"):
        return {
            "ok": True,
            "run": {
                "id": "agr_0123456789ab",
                "status": status,
                "mode": mode,
                "model": None,
                "thinkingLevel": None,
                "prompt": "What changed?",
                "response": "An answer" if status in {"completed", "promoted"} else None,
                "error": None,
                "createdAt": "2026-08-25T00:00:00Z",
                "startedAt": "2026-08-25T00:00:01Z",
                "finishedAt": "2026-08-25T00:00:02Z",
                "threadRootRunId": "agr_0123456789ab",
                "sessionId": "session-1",
                "sessionFile": "/private/run/session.jsonl",
                "costUSD": 0.01,
                "promotedWorkspaceId": "w1" if status == "promoted" else None,
                "promotedPaneId": "w1:p1" if status == "promoted" else None,
                "attachments": [],
            },
        }

    def start_agent_run(
        self,
        *,
        prompt,
        label=None,
        mode="ask",
        model=None,
        thinking_level=None,
        attachments=None,
        system_prompt=None,
        continue_from_run_id=None,
    ):
        self.calls.append(
            (
                "agent_run.start",
                {
                    "prompt": prompt,
                    "label": label,
                    "mode": mode,
                    "model": model,
                    "thinking_level": thinking_level,
                    "attachments": attachments,
                    "system_prompt": system_prompt,
                    "continue_from_run_id": continue_from_run_id,
                },
            )
        )
        result = self._agent_run("queued", mode=mode)
        result["run"]["prompt"] = prompt
        if model is not None:
            result["run"]["model"] = model
        if thinking_level is not None:
            result["run"]["thinkingLevel"] = thinking_level
        if attachments is not None:
            result["run"]["attachments"] = [item["filename"] for item in attachments]
        return result

    def get_agent_run(self, run_id):
        self.calls.append(("agent_run.get", {"run_id": run_id}))
        return self._agent_run()

    def list_agent_models(self):
        self.calls.append(("agent_models.list", {}))
        return {
            "ok": True,
            "models": [
                {
                    "provider": "openai-codex",
                    "id": "gpt-5.6-luna",
                    "contextWindow": 272000,
                    "supportsImages": True,
                    "reasoning": True,
                }
            ],
            "default": {"provider": "openai-codex", "id": "gpt-5.6-luna"},
        }

    def agent_prompt_defaults(self):
        self.calls.append(("agent_prompt_defaults", {}))
        return {"ok": True, "prompts": {"act": "act", "ask": "ask", "cleanupJudge": "cleanup"}}

    def cancel_agent_run(self, run_id):
        self.calls.append(("agent_run.cancel", {"run_id": run_id}))
        return self._agent_run("cancelled")

    def promote_agent_run(
        self,
        run_id,
        *,
        workspace_id=None,
        cwd=None,
        workspace_label=None,
    ):
        self.calls.append(
            (
                "agent_run.promote",
                {
                    "run_id": run_id,
                    "workspace_id": workspace_id,
                    "cwd": cwd,
                    "workspace_label": workspace_label,
                },
            )
        )
        return self._agent_run("promoted")

    def delete_agent_run(self, run_id):
        self.calls.append(("agent_run.delete", {"run_id": run_id}))
        return self._agent_run("cancelled")

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
        if self.pi_command_error is not None:
            raise self.pi_command_error
        return {"ok": True, "success": True, "result": {"accepted": True}}

    def list_alerts(self, **_options):
        return {"ok": True, "alerts": [{"id": "alert_1", "isRead": False}], "unreadCount": 1}

    def mark_alert_read(self, alert_id):
        if alert_id != "alert_1":
            return None
        return {"ok": True, "alert": {"id": alert_id, "isRead": True}, "unreadCount": 0}

    def mark_all_alerts_read(self):
        return {"ok": True, "alerts": [], "unreadCount": 0}

    def mark_pane_alerts_read(self, pane_id):
        self.calls.append(("pane.alerts.read", {"pane_id": pane_id}))
        if pane_id != "w1:p1":
            return None
        return {"ok": True, "paneId": pane_id, "alerts": [], "unreadCount": 0}

    def set_pane_star(self, pane_id, starred):
        self.calls.append(("pane.star", {"pane_id": pane_id, "starred": starred}))
        return {
            "ok": True,
            "paneId": pane_id,
            "starred": starred,
            "starredPaneIds": ["w1:p1"] if starred else [],
            "generatedAt": "now",
        }

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

    def register_live_activity(
        self,
        push_token,
        *,
        activity_id,
        bundle_id,
        environment,
        reveal_session_titles=True,
    ):
        self.calls.append(
            (
                "live_activity.register",
                {
                    "pushToken": push_token,
                    "activityId": activity_id,
                    "bundleId": bundle_id,
                    "environment": environment,
                    "revealSessionTitles": reveal_session_titles,
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

    def test_response_audio_routes_are_authenticated_and_delegate_bounded_payloads(self):
        status, _, capabilities = self.request("/api/v1/response-audio/capabilities")
        self.assertEqual(status, 200)
        self.assertTrue(capabilities["listen"])
        self.assertTrue(capabilities["tldr"])

        status, _, prepared = self.request(
            "/api/v1/response-audio/prepare",
            method="POST",
            payload={"action": "tldr", "text": "A detailed completed response."},
        )
        self.assertEqual(status, 200)
        self.assertEqual(prepared["chunks"], ["Prepared response"])

        status, _, speech = self.request(
            "/api/v1/response-audio/speech",
            method="POST",
            payload={"text": prepared["chunks"][0]},
        )
        self.assertEqual(status, 200)
        self.assertEqual(speech["contentType"], "audio/mpeg")
        self.assertEqual(
            self.service.calls[-3:],
            [
                ("response_audio.capabilities", {}),
                (
                    "response_audio.prepare",
                    {"action": "tldr", "text": "A detailed completed response."},
                ),
                ("response_audio.speech", {"text": "Prepared response"}),
            ],
        )

        status, _, body = self.request(
            "/api/v1/response-audio/prepare",
            method="POST",
            payload={"action": "listen", "text": "Hello", "unexpected": True},
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_request")

        status, _, body = self.request("/api/v1/response-audio/capabilities", token=None)
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

    def test_herdr_web_redirect_preserves_reverse_proxy_prefixes(self):
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_address[1],
            timeout=2,
        )
        self.addCleanup(connection.close)

        connection.request("GET", "/herdr-web")
        response = connection.getresponse()
        response.read()

        self.assertEqual(response.status, 308)
        self.assertEqual(response.getheader("Location"), "herdr-web/")
        self.assertEqual(
            urllib.parse.urljoin(
                "https://herdr.example.test/base/herdr-web",
                response.getheader("Location"),
            ),
            "https://herdr.example.test/base/herdr-web/",
        )

    def test_board_page_serves_pre_auth_and_relative_redirect_preserves_reverse_proxy_prefixes(
        self,
    ):
        with urllib.request.urlopen(self.base + "/board/", timeout=2) as response:
            status = response.status
            content_type = response.headers.get("Content-Type", "")
            body = response.read().decode("utf-8")

        self.assertEqual(status, 200)
        self.assertIn("text/html", content_type)
        self.assertIn("Herdr Buzz Trail", body)

        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_address[1],
            timeout=2,
        )
        self.addCleanup(connection.close)
        connection.request("GET", "/board")
        response = connection.getresponse()
        response.read()

        self.assertEqual(response.status, 308)
        self.assertEqual(response.getheader("Location"), "board/")
        self.assertEqual(
            urllib.parse.urljoin(
                "https://herdr.example.test/base/board",
                response.getheader("Location"),
            ),
            "https://herdr.example.test/base/board/",
        )

    def test_board_page_styles_activity_messages(self):
        with urllib.request.urlopen(self.base + "/board/", timeout=2) as response:
            body = response.read().decode("utf-8")

        self.assertEqual(response.status, 200)
        self.assertIn(".act-bubble", body)
        self.assertIn(".act-chip", body)
        self.assertNotIn("Bangers", body)

    def test_api_description_lists_workflow_and_board_endpoints(self):
        status, _, body = self.request("/api/v1")

        self.assertEqual(status, 200)
        self.assertEqual(
            body["endpoints"]["activeWorkWorkflows"],
            "/api/v1/active-work/workflows",
        )
        self.assertEqual(body["endpoints"]["board"], "/board")
        self.assertIn("POST /api/v1/active-work/workflows", body["mutations"])

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
        self.assertIn("starredPaneIds", workspaces)

    def test_pane_star_route_validates_and_forwards(self):
        status, _, body = self.request(
            "/api/v1/panes/w1:p1/star",
            method="POST",
            payload={"starred": True},
        )

        self.assertEqual(status, 200)
        self.assertTrue(body["starred"])
        self.assertEqual(
            self.service.calls[-1],
            ("pane.star", {"pane_id": "w1:p1", "starred": True}),
        )

        missing_status, _, missing_body = self.request(
            "/api/v1/panes/w1:p1/star",
            method="POST",
            payload={},
        )
        self.assertEqual(missing_status, 400)
        self.assertEqual(missing_body["error"]["code"], "invalid_request")

        bad_type_status, _, bad_type_body = self.request(
            "/api/v1/panes/w1:p1/star",
            method="POST",
            payload={"starred": "yes"},
        )
        self.assertEqual(bad_type_status, 400)
        self.assertEqual(bad_type_body["error"]["code"], "invalid_request")

    def test_pane_alerts_read_route_forwards_and_returns_pane_response(self):
        status, _, body = self.request(
            "/api/v1/panes/w1:p1/alerts/read",
            method="POST",
            payload={},
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            body,
            {"ok": True, "paneId": "w1:p1", "alerts": [], "unreadCount": 0},
        )
        self.assertEqual(self.service.calls[-1], ("pane.alerts.read", {"pane_id": "w1:p1"}))

    def test_pane_alerts_read_route_projects_done_pane_as_idle_with_no_unread_alerts(self):
        service = HerdrService(FakeClient([snapshot_with_status("done")]), environ={})
        service.refresh_snapshot()
        service.alerts.mark_all_read()
        server = make_server(service, host="127.0.0.1", port=0, api_token="test-secret")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            request = urllib.request.Request(
                base + "/api/v1/panes/w1:p1/alerts/read",
                method="POST",
                data=b"{}",
                headers={
                    "Authorization": "Bearer test-secret",
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                status = response.status
                read_response = json.loads(response.read())
            workspace_request = urllib.request.Request(
                base + "/api/v1/workspaces",
                headers={"Authorization": "Bearer test-secret"},
            )
            with urllib.request.urlopen(workspace_request, timeout=2) as response:
                workspaces = json.loads(response.read())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

        self.assertEqual(status, 200)
        self.assertTrue(read_response["ok"])
        self.assertEqual(read_response["alerts"], [])
        self.assertEqual(workspaces["workspaces"][0]["panes"][0]["agent_status"], "idle")

    def test_pane_alerts_read_route_returns_not_found_for_unknown_pane(self):
        status, _, body = self.request(
            "/api/v1/panes/does-not-exist/alerts/read",
            method="POST",
            payload={},
        )

        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "pane_not_found")

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

    def test_quick_pi_session_route_validates_and_forwards_label(self):
        status, _, body = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={"label": "aug 18, 2:34 pm"},
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            body,
            {
                "ok": True,
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "pane_id": "w1:p1",
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
            self.service.calls[-1],
            (
                "quick_pi_session",
                {
                    "label": "aug 18, 2:34 pm",
                    "workspace_id": None,
                    "tab_id": None,
                    "cwd": None,
                    "session_file": None,
                    "session_id": None,
                    "request_id": None,
                },
            ),
        )

        for label in ("", "   ", "x" * 121):
            with self.subTest(label=label):
                invalid_status, _, invalid_body = self.request(
                    "/api/v1/quick-sessions/pi",
                    method="POST",
                    payload={"label": label},
                )
                self.assertEqual(invalid_status, 400)
                self.assertEqual(invalid_body["error"]["code"], "invalid_request")

    def test_quick_pi_session_forwards_optional_placement_and_resume_fields(self):
        status, _, _ = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={
                "label": "Project question",
                "workspaceId": "w1",
                "tabId": "w1:t1",
                "cwd": "/tmp",
                "sessionFile": "/tmp/pi-session.jsonl",
                "sessionId": "pi-session-1",
                "requestId": "request-1",
            },
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            self.service.calls[-1],
            (
                "quick_pi_session",
                {
                    "label": "Project question",
                    "workspace_id": "w1",
                    "tab_id": "w1:t1",
                    "cwd": "/tmp",
                    "session_file": "/tmp/pi-session.jsonl",
                    "session_id": "pi-session-1",
                    "request_id": "request-1",
                },
            ),
        )

        invalid_status, _, invalid_body = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={"label": "Project question", "tabId": "not/a/tab"},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_request")

        call_count = len(self.service.calls)
        missing_file_status, _, missing_file_body = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={"label": "Project question", "sessionId": "pi-session-1"},
        )
        self.assertEqual(missing_file_status, 400)
        self.assertEqual(missing_file_body["error"]["code"], "invalid_request")
        self.assertEqual(len(self.service.calls), call_count)

    def test_quick_pi_session_forwards_named_tab_options(self):
        status, _, _ = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={
                "label": "Project question",
                "workspaceLabel": "W",
                "tabLabel": "T",
                "reuseNamedTab": False,
            },
        )

        self.assertEqual(status, 200)
        call = self.service.calls[-1][1]
        self.assertEqual(call["workspace_label"], "W")
        self.assertEqual(call["tab_label"], "T")
        self.assertFalse(call["reuse_named_tab"])

        status, _, _ = self.request(
            "/api/v1/quick-sessions/pi",
            method="POST",
            payload={"label": "Project question"},
        )
        self.assertEqual(status, 200)
        self.assertNotIn("reuse_named_tab", self.service.calls[-1][1])
        self.assertNotIn("workspace_label", self.service.calls[-1][1])
        self.assertNotIn("tab_label", self.service.calls[-1][1])

    def test_agent_run_routes_use_async_start_and_stable_envelope(self):
        status, _, body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "What changed?"},
        )

        self.assertEqual(status, 202)
        self.assertEqual(body["run"]["status"], "queued")
        self.assertEqual(
            set(body["run"]),
            {
                "id",
                "status",
                "mode",
                "model",
                "thinkingLevel",
                "prompt",
                "response",
                "error",
                "createdAt",
                "startedAt",
                "finishedAt",
                "threadRootRunId",
                "sessionId",
                "sessionFile",
                "costUSD",
                "promotedWorkspaceId",
                "promotedPaneId",
                "attachments",
            },
        )
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent_run.start",
                {
                    "prompt": "What changed?",
                    "label": None,
                    "mode": "ask",
                    "model": None,
                    "thinking_level": None,
                    "attachments": None,
                    "system_prompt": None,
                    "continue_from_run_id": None,
                },
            ),
        )

        get_status, _, get_body = self.request("/api/v1/agent-runs/agr_0123456789ab")
        self.assertEqual(get_status, 200)
        self.assertEqual(get_body["run"]["status"], "completed")

        cancel_status, _, cancel_body = self.request(
            "/api/v1/agent-runs/agr_0123456789ab/cancel",
            method="POST",
            payload={},
        )
        self.assertEqual(cancel_status, 200)
        self.assertEqual(cancel_body["run"]["status"], "cancelled")

    def test_agent_models_route_uses_catalog_envelope(self):
        status, _, body = self.request("/api/v1/agent-runs/models")

        self.assertEqual(status, 200)
        self.assertEqual(
            body,
            {
                "ok": True,
                "models": [
                    {
                        "provider": "openai-codex",
                        "id": "gpt-5.6-luna",
                        "contextWindow": 272000,
                        "supportsImages": True,
                        "reasoning": True,
                    }
                ],
                "default": {"provider": "openai-codex", "id": "gpt-5.6-luna"},
            },
        )
        self.assertEqual(self.service.calls[-1], ("agent_models.list", {}))

    def test_agent_prompts_route_uses_defaults_envelope(self):
        status, _, body = self.request("/api/v1/agent-runs/prompts")

        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(set(body["prompts"]), {"act", "ask", "cleanupJudge"})
        self.assertEqual(self.service.calls[-1], ("agent_prompt_defaults", {}))

    def test_agent_run_system_prompt_is_validated_and_forwarded(self):
        status, _, _ = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "What changed?", "systemPrompt": "Custom instructions"},
        )

        self.assertEqual(status, 202)
        self.assertEqual(self.service.calls[-1][1]["system_prompt"], "Custom instructions")

        for system_prompt, expected_message in (
            ("", "systemPrompt is required"),
            ("   ", "systemPrompt is invalid"),
            ("x" * 32769, "systemPrompt exceeds 32768 characters"),
        ):
            with self.subTest(system_prompt=system_prompt):
                invalid_status, _, invalid_body = self.request(
                    "/api/v1/agent-runs",
                    method="POST",
                    payload={"prompt": "What changed?", "systemPrompt": system_prompt},
                )
                self.assertEqual(invalid_status, 400)
                self.assertEqual(invalid_body["error"]["message"], expected_message)

    def test_cleanup_run_forwards_judge_charter(self):
        status, _, _ = self.request(
            "/api/v1/cleanup/runs",
            method="POST",
            payload={"judgeCharter": "Be extra careful."},
        )

        self.assertEqual(status, 202)
        self.assertEqual(
            self.service.calls[-1],
            ("cleanup.start_run", {"judgeCharter": "Be extra careful."}),
        )

        for judge_charter in ("", "   ", "x" * 32769):
            with self.subTest(judge_charter=judge_charter):
                invalid_status, _, _ = self.request(
                    "/api/v1/cleanup/runs",
                    method="POST",
                    payload={"judgeCharter": judge_charter},
                )
                self.assertEqual(invalid_status, 400)

    def test_agent_run_mode_rides_the_start_request_and_rejects_invalid_values(self):
        status, _, body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "Open the browser", "mode": "act"},
        )

        self.assertEqual(status, 202)
        self.assertEqual(body["run"]["mode"], "act")
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent_run.start",
                {
                    "prompt": "Open the browser",
                    "label": None,
                    "mode": "act",
                    "model": None,
                    "thinking_level": None,
                    "attachments": None,
                    "system_prompt": None,
                    "continue_from_run_id": None,
                },
            ),
        )

        call_count = len(self.service.calls)
        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "mode": "bogus"},
        )

        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_request")
        self.assertEqual(len(self.service.calls), call_count)

        unhashable_status, _, unhashable_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "mode": {"nested": 1}},
        )

        self.assertEqual(unhashable_status, 400)
        self.assertEqual(unhashable_body["error"]["code"], "invalid_request")
        self.assertEqual(len(self.service.calls), call_count)

    def test_agent_run_continuation_is_validated_and_forwarded(self):
        run_id = "agr_0123456789ab"
        status, _, body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "Follow up", "continueFromRunId": run_id},
        )

        self.assertEqual(status, 202)
        self.assertEqual(body["run"]["threadRootRunId"], run_id)
        self.assertEqual(
            self.service.calls[-1][1]["continue_from_run_id"],
            run_id,
        )

        call_count = len(self.service.calls)
        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "Follow up", "continueFromRunId": "not-a-run-id"},
        )

        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_request")
        self.assertEqual(len(self.service.calls), call_count)

    def test_agent_run_model_and_thinking_level_are_validated_and_forwarded(self):
        model = "accounts/fireworks/models/deepseek-v4-flash-0731"
        status, _, body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "Look at this", "model": model, "thinkingLevel": "high"},
        )

        self.assertEqual(status, 202)
        self.assertEqual(body["run"]["model"], model)
        self.assertEqual(body["run"]["thinkingLevel"], "high")
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent_run.start",
                {
                    "prompt": "Look at this",
                    "label": None,
                    "mode": "ask",
                    "model": model,
                    "thinking_level": "high",
                    "attachments": None,
                    "system_prompt": None,
                    "continue_from_run_id": None,
                },
            ),
        )

        call_count = len(self.service.calls)
        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "model": "bad model!"},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_agent_model")
        self.assertEqual(len(self.service.calls), call_count)

        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "thinkingLevel": "ultra"},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_agent_thinking_level")
        self.assertEqual(len(self.service.calls), call_count)

    def test_agent_run_attachments_are_shape_validated_and_forwarded(self):
        attachment = {"filename": "a.png", "dataBase64": "aGVsbG8="}
        status, _, _ = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "Look at this", "attachments": [attachment]},
        )

        self.assertEqual(status, 202)
        self.assertEqual(self.service.calls[-1][1]["attachments"], [attachment])

        call_count = len(self.service.calls)
        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "attachments": "not-a-list"},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_agent_attachment")
        self.assertEqual(len(self.service.calls), call_count)

        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "attachments": [attachment] * 5},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_agent_attachment")
        self.assertEqual(len(self.service.calls), call_count)

        invalid_status, _, invalid_body = self.request(
            "/api/v1/agent-runs",
            method="POST",
            payload={"prompt": "x", "attachments": [{"filename": "a.png"}]},
        )
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid_body["error"]["code"], "invalid_agent_attachment")
        self.assertEqual(len(self.service.calls), call_count)

    def test_agent_run_promote_and_delete_forward_validated_options(self):
        status, _, body = self.request(
            "/api/v1/agent-runs/agr_0123456789ab/promote",
            method="POST",
            payload={
                "workspaceId": "w1",
                "cwd": "/tmp",
                "workspaceLabel": "Agent chats",
            },
        )

        self.assertEqual(status, 200)
        self.assertEqual(body["run"]["status"], "promoted")
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent_run.promote",
                {
                    "run_id": "agr_0123456789ab",
                    "workspace_id": "w1",
                    "cwd": "/tmp",
                    "workspace_label": "Agent chats",
                },
            ),
        )

        delete_status, _, delete_body = self.request(
            "/api/v1/agent-runs/agr_0123456789ab",
            method="DELETE",
            payload={},
        )
        self.assertEqual(delete_status, 200)
        self.assertEqual(delete_body["run"]["status"], "cancelled")
        self.assertEqual(
            self.service.calls[-1],
            ("agent_run.delete", {"run_id": "agr_0123456789ab"}),
        )

    def test_start_agent_injects_pi_extension_only_when_args_are_empty(self):
        path = "/api/v1/panes/w1:p1/start-agent"
        expected = {
            "pane_id": "w1:p1",
            "name": "n",
            "kind": "pi",
            "args": ["--extension", "/fake/bridge"],
            "timeout_ms": 30000,
        }

        for payload in (
            {"name": "n", "kind": "pi"},
            {"name": "n", "kind": "pi", "args": []},
        ):
            with self.subTest(payload=payload):
                status, _, _ = self.request(path, method="POST", payload=payload)
                self.assertEqual(status, 200)
                self.assertEqual(self.service.calls[-1], ("agent.start", expected))
        self.assertEqual(self.service.pi_extension_args_calls, 2)

        status, _, _ = self.request(
            path,
            method="POST",
            payload={"name": "n", "kind": "pi", "args": ["--foo"]},
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent.start",
                {**expected, "args": ["--foo"]},
            ),
        )
        self.assertEqual(self.service.pi_extension_args_calls, 2)

        status, _, _ = self.request(
            path,
            method="POST",
            payload={"name": "n", "kind": "codex", "args": []},
        )
        self.assertEqual(status, 200)
        self.assertEqual(
            self.service.calls[-1],
            (
                "agent.start",
                {**expected, "kind": "codex", "args": []},
            ),
        )
        self.assertEqual(self.service.pi_extension_args_calls, 2)

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
            ("/api/v1/panes/w1:p1/zoom", {"mode": "on"}, "pane.zoom"),
            ("/api/v1/panes/w1:p1/zoom", {}, "pane.zoom"),
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
        self.assertEqual(self.service.calls[3][1], {"pane_id": "w1:p1", "mode": "on"})
        self.assertEqual(self.service.calls[4][1], {"pane_id": "w1:p1", "mode": "toggle"})

    def test_invalid_zoom_mode_is_rejected(self):
        status, _, body = self.request(
            "/api/v1/panes/w1:p1/zoom", method="POST", payload={"mode": "sideways"}
        )

        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_request")
        self.assertEqual(self.service.calls, [])

    def test_split_response_includes_pane_id_when_available(self):
        self.service.split_result = {"pane": {"pane_id": "w1:p9"}}

        status, _, body = self.request(
            "/api/v1/panes/w1:p1/split", method="POST", payload={"direction": "right"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(body["paneId"], "w1:p9")
        self.assertEqual(body["result"], {"pane": {"pane_id": "w1:p9"}})

    def test_split_response_includes_null_pane_id_when_unavailable(self):
        status, _, body = self.request("/api/v1/panes/w1:p1/split", method="POST", payload={})

        self.assertEqual(status, 200)
        self.assertIsNone(body["paneId"])

    def test_pane_rename_fans_out_to_tab_when_tab_has_a_single_pane(self):
        self.service.snapshot["tabs"] = [{"tab_id": "t1", "workspace_id": "w1"}]
        self.service.snapshot["panes"] = [{"pane_id": "w1:p1", "tab_id": "t1", "workspace_id": "w1"}]

        status, _, body = self.request(
            "/api/v1/panes/w1:p1", method="PATCH", payload={"label": "renamed"}
        )

        self.assertEqual(status, 200)
        self.assertTrue(body["tabRenamed"])
        self.assertEqual(
            self.service.calls,
            [
                ("pane.rename", {"pane_id": "w1:p1", "label": "renamed"}),
                ("tab.rename", {"tab_id": "t1", "label": "renamed"}),
            ],
        )

    def test_pane_rename_does_not_fan_out_when_tab_has_multiple_panes(self):
        self.service.snapshot["tabs"] = [{"tab_id": "t1", "workspace_id": "w1"}]
        self.service.snapshot["panes"] = [
            {"pane_id": "w1:p1", "tab_id": "t1", "workspace_id": "w1"},
            {"pane_id": "w1:p2", "tab_id": "t1", "workspace_id": "w1"},
        ]

        status, _, body = self.request(
            "/api/v1/panes/w1:p1", method="PATCH", payload={"label": "renamed"}
        )

        self.assertEqual(status, 200)
        self.assertFalse(body["tabRenamed"])
        self.assertEqual(
            self.service.calls,
            [("pane.rename", {"pane_id": "w1:p1", "label": "renamed"})],
        )

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

    def test_pane_git_routes_are_authenticated_and_forward_no_client_root(self):
        status_code, _, status = self.request(
            "/api/v1/panes/w1:p1/git?path=/client/cannot/choose"
        )
        diff_code, _, diff = self.request(
            "/api/v1/panes/w1:p1/git/diff?file=Sources%2FPane.swift&section=unstaged"
            "&expected_root=%2Fserver%2Fresolved%2Fpane-repo"
        )
        stage_code, _, _ = self.request(
            "/api/v1/panes/w1:p1/git/stage",
            method="POST",
            payload={
                "file": "Sources/Pane.swift",
                "expected_root": "/server/resolved/pane-repo",
                "path": "/client/cannot/choose",
            },
        )
        unstage_code, _, _ = self.request(
            "/api/v1/panes/w1:p1/git/unstage",
            method="POST",
            payload={
                "file": "Sources/Pane.swift",
                "expected_root": "/server/resolved/pane-repo",
            },
        )
        files_code, _, files = self.request(
            "/api/v1/panes/w1:p1/git/commit-files?hash=a1b2c3d"
            "&expected_root=%2Fserver%2Fresolved%2Fpane-repo"
        )
        historical_code, _, historical = self.request(
            "/api/v1/panes/w1:p1/git/commit-diff?hash=a1b2c3d&file=Sources%2FPane.swift"
            "&expected_root=%2Fserver%2Fresolved%2Fpane-repo"
        )
        unauthorized, _, auth_body = self.request(
            "/api/v1/panes/w1:p1/git",
            token=None,
        )

        self.assertEqual(
            [
                status_code,
                diff_code,
                stage_code,
                unstage_code,
                files_code,
                historical_code,
            ],
            [200, 200, 200, 200, 200, 200],
        )
        self.assertEqual(status["root_path"], "/server/resolved/pane-repo")
        self.assertEqual(diff["diff"], "+change")
        self.assertEqual(files["files"], [{"status": "M", "file": "Sources/Pane.swift"}])
        self.assertEqual(historical["diff"], "+historical")
        self.assertEqual(unauthorized, 401)
        self.assertEqual(auth_body["error"]["code"], "unauthorized")
        self.assertIn(("pane.git", {"pane_id": "w1:p1"}), self.service.calls)
        self.assertIn(
            (
                "pane.git.commit-diff",
                {
                    "pane_id": "w1:p1",
                    "hash": "a1b2c3d",
                    "file": "Sources/Pane.swift",
                    "expected_root": "/server/resolved/pane-repo",
                },
            ),
            self.service.calls,
        )
        self.assertNotIn("/client/cannot/choose", repr(self.service.calls))

    def test_pane_git_routes_validate_required_query_and_body_values(self):
        missing_file, _, missing_file_body = self.request(
            "/api/v1/panes/w1:p1/git/diff?section=unstaged"
        )
        missing_hash, _, missing_hash_body = self.request(
            "/api/v1/panes/w1:p1/git/commit-files"
        )
        missing_stage_file, _, missing_stage_file_body = self.request(
            "/api/v1/panes/w1:p1/git/stage",
            method="POST",
            payload={},
        )
        missing_expected_root, _, missing_expected_root_body = self.request(
            "/api/v1/panes/w1:p1/git/stage",
            method="POST",
            payload={"file": "Sources/Pane.swift"},
        )
        missing_diff_root, _, missing_diff_root_body = self.request(
            "/api/v1/panes/w1:p1/git/diff?file=Sources%2FPane.swift&section=unstaged"
        )
        missing_files_root, _, missing_files_root_body = self.request(
            "/api/v1/panes/w1:p1/git/commit-files?hash=a1b2c3d"
        )
        missing_commit_diff_root, _, missing_commit_diff_root_body = self.request(
            "/api/v1/panes/w1:p1/git/commit-diff?hash=a1b2c3d&file=Sources%2FPane.swift"
        )

        self.assertEqual(
            [
                missing_file,
                missing_hash,
                missing_stage_file,
                missing_expected_root,
                missing_diff_root,
                missing_files_root,
                missing_commit_diff_root,
            ],
            [400, 400, 400, 400, 400, 400, 400],
        )
        self.assertEqual(missing_file_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_hash_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_stage_file_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_expected_root_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_diff_root_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_files_root_body["error"]["code"], "invalid_request")
        self.assertEqual(missing_commit_diff_root_body["error"]["code"], "invalid_request")

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

    def test_sse_without_cursor_sends_one_synthetic_refresh_not_ring_replay(self):
        self.service.broker.publish("pane.focused", {"pane_id": "old"})
        self.service.broker.publish("snapshot.updated", {"paneRevisions": {"old": 1}})

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
        self.assertIn("event: ready", payload)
        self.assertEqual(payload.count("event: snapshot.updated"), 1)
        self.assertIn('"synthetic":true', payload)
        self.assertNotIn("event: pane.focused", payload)
        ready = json.loads(next(line[6:] for line in payload.splitlines() if line.startswith("data: ")))
        self.assertEqual(ready["resumeFrom"], 2)

        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=2)
        connection.request(
            "GET",
            "/api/v1/events?once=true&after=0",
            headers={"Authorization": "Bearer test-secret"},
        )
        response = connection.getresponse()
        replay = response.read().decode()
        connection.close()
        self.assertIn("event: pane.focused", replay)
        self.assertEqual(replay.count("event: snapshot.updated"), 1)
        self.assertNotIn('"synthetic":true', replay)

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
        models_status, _, models = self.request("/api/v1/panes/w1:p1/pi/models")
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
        compact_status, _, _ = self.request(
            "/api/v1/panes/w1:p1/pi/compact",
            method="POST",
            payload={},
        )

        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["protocol"], {"name": "herdr.pi.semantic", "version": 1})
        self.assertEqual(snapshot["entries"][0]["id"], "entry-1")
        self.assertFalse(snapshot["connected"])
        self.assertEqual(models_status, 200)
        self.assertTrue(models["success"])
        self.assertEqual(prompt_status, 200)
        self.assertTrue(prompt["success"])
        self.assertEqual(follow_status, 200)
        self.assertEqual(abort_status, 200)
        self.assertEqual(compact_status, 200)
        self.assertIn(("pi.prompt", {"pane_id": "w1:p1", "payload": {"text": "Fix the tests"}}), self.service.calls)
        self.assertIn(("pi.follow_up", {"pane_id": "w1:p1", "payload": {"text": "Then review it"}}), self.service.calls)
        self.assertIn(("pi.abort", {"pane_id": "w1:p1", "payload": {}}), self.service.calls)
        self.assertIn(("pi.compact", {"pane_id": "w1:p1", "payload": {}}), self.service.calls)
        self.assertIn(("pi.list_models", {"pane_id": "w1:p1", "payload": {}}), self.service.calls)

    def test_pi_model_route_validates_and_forwards(self):
        valid_status, _, valid = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"provider": "anthropic", "id": "claude-sonnet"},
        )
        missing_provider_status, _, missing_provider = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"id": "claude-sonnet"},
        )
        empty_provider_status, _, empty_provider = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"provider": "", "id": "claude-sonnet"},
        )
        missing_id_status, _, missing_id = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"provider": "anthropic"},
        )
        extra_key_status, _, extra_key = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"provider": "anthropic", "id": "claude-sonnet", "extra": "nope"},
        )

        self.assertEqual(valid_status, 200)
        self.assertTrue(valid["success"])
        for status, response in (
            (missing_provider_status, missing_provider),
            (empty_provider_status, empty_provider),
            (missing_id_status, missing_id),
            (extra_key_status, extra_key),
        ):
            self.assertEqual(status, 400)
            self.assertEqual(response["error"]["code"], "invalid_request")
        self.assertIn(
            (
                "pi.set_model",
                {
                    "pane_id": "w1:p1",
                    "payload": {"provider": "anthropic", "id": "claude-sonnet"},
                },
            ),
            self.service.calls,
        )

    def test_pi_model_route_errors_map_to_the_bridges_reported_http_status(self):
        self.service.pi_command_error = PiSemanticError("Unsupported Pi command", code="unsupported", status=501)
        unsupported_status, _, unsupported_body = self.request("/api/v1/panes/w1:p1/pi/models")

        self.service.pi_command_error = PiSemanticError("Pi rejected the command", code="command_rejected", status=409)
        rejected_status, _, rejected_body = self.request(
            "/api/v1/panes/w1:p1/pi/model",
            method="POST",
            payload={"provider": "anthropic", "id": "claude-sonnet"},
        )
        self.service.pi_command_error = None

        self.assertEqual(unsupported_status, 501)
        self.assertEqual(unsupported_body["error"]["code"], "unsupported")
        self.assertEqual(rejected_status, 409)
        self.assertEqual(rejected_body["error"]["code"], "command_rejected")

    def test_pi_thinking_level_route_validates_and_forwards(self):
        valid_status, _, valid = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={"level": "high"},
        )
        missing_level_status, _, missing_level = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={},
        )
        empty_level_status, _, empty_level = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={"level": ""},
        )
        extra_key_status, _, extra_key = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={"level": "high", "extra": "nope"},
        )

        self.assertEqual(valid_status, 200)
        self.assertTrue(valid["success"])
        for status, response in (
            (missing_level_status, missing_level),
            (empty_level_status, empty_level),
            (extra_key_status, extra_key),
        ):
            self.assertEqual(status, 400)
            self.assertEqual(response["error"]["code"], "invalid_request")
        self.assertIn(
            (
                "pi.set_thinking_level",
                {
                    "pane_id": "w1:p1",
                    "payload": {"level": "high"},
                },
            ),
            self.service.calls,
        )

    def test_pi_thinking_level_route_errors_map_to_the_bridges_reported_http_status(self):
        self.service.pi_command_error = PiSemanticError("Unsupported Pi command", code="unsupported", status=501)
        unsupported_status, _, unsupported_body = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={"level": "high"},
        )

        self.service.pi_command_error = PiSemanticError("Pi rejected the command", code="command_rejected", status=409)
        rejected_status, _, rejected_body = self.request(
            "/api/v1/panes/w1:p1/pi/thinking-level",
            method="POST",
            payload={"level": "high"},
        )
        self.service.pi_command_error = None

        self.assertEqual(unsupported_status, 501)
        self.assertEqual(unsupported_body["error"]["code"], "unsupported")
        self.assertEqual(rejected_status, 409)
        self.assertEqual(rejected_body["error"]["code"], "command_rejected")

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
                "revealSessionTitles": False,
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
        self.assertFalse(self.service.calls[-2][1]["revealSessionTitles"])
        self.assertEqual(unregistered, 200)
        self.assertEqual(self.service.calls[-2][0], "live_activity.register")
        self.assertEqual(self.service.calls[-1][0], "live_activity.unregister")


    def test_apple_app_site_association_is_public(self):
        with urllib.request.urlopen(self.base + "/.well-known/apple-app-site-association", timeout=2) as response:
            payload = json.loads(response.read())
            content_type = response.headers.get("Content-Type", "")

        detail = payload["applinks"]["details"][0]
        self.assertIn("application/json", content_type)
        self.assertEqual(
            detail["appIDs"],
            ["L2M32HMQZH.dev.ronnierocha.herdr-harness.herdr-harness-ios"],
        )
        self.assertEqual(detail["components"], [{"/": "/open/*"}])

    def test_apple_app_site_association_honors_app_id_override(self):
        service = FakeHTTPService()
        service.environ = {"HERDR_HARNESS_APP_IDS": "TEAM1.example.app, TEAM2.example.other"}
        server = make_server(service, host="127.0.0.1", port=0, api_token="test-secret")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            with urllib.request.urlopen(base + "/apple-app-site-association", timeout=2) as response:
                payload = json.loads(response.read())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

        self.assertEqual(
            payload["applinks"]["details"][0]["appIDs"],
            ["TEAM1.example.app", "TEAM2.example.other"],
        )

    def test_open_pane_fallback_page_is_public_and_escapes_the_id(self):
        with urllib.request.urlopen(self.base + "/open/pane/w%3Ap4", timeout=2) as response:
            page = response.read().decode()

        status, _, body = self.request("/open/other", token=None)

        self.assertIn("herdr://pane/w%3Ap4", page)
        self.assertIn("w:p4", page)
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")

    def test_open_pane_fallback_page_rejects_non_identifier_ids(self):
        markup_status, _, markup_body = self.request(
            "/open/pane/%3Cscript%3Ealert(1)%3C%2Fscript%3E", token=None
        )
        oversized_status, _, _ = self.request("/open/pane/" + "a" * 200, token=None)

        self.assertEqual(markup_status, 404)
        self.assertEqual(markup_body["error"]["code"], "not_found")
        self.assertEqual(oversized_status, 404)

    def test_pane_link_requires_token_and_builds_urls_from_public_url(self):
        service = FakeHTTPService()
        service.environ = {"HERDR_HARNESS_PUBLIC_URL": "https://rocketbot.tail1db61d.ts.net:8461"}
        server = make_server(service, host="127.0.0.1", port=0, api_token="test-secret")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            request = urllib.request.Request(
                base + "/api/v1/panes/w:p4/link",
                headers={"Authorization": "Bearer test-secret"},
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                body = json.loads(response.read())
            try:
                with urllib.request.urlopen(base + "/api/v1/panes/w:p4/link", timeout=2):
                    unauthorized = 200
            except urllib.error.HTTPError as exc:
                unauthorized = exc.code
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

        self.assertEqual(unauthorized, 401)
        self.assertTrue(body["ok"])
        self.assertEqual(body["paneId"], "w:p4")
        self.assertEqual(body["customSchemeLink"], "herdr://pane/w%3Ap4")
        self.assertEqual(
            body["universalLink"],
            "https://rocketbot.tail1db61d.ts.net:8461/open/pane/w%3Ap4",
        )
        self.assertEqual(body["baseUrlSource"], "environment")


if __name__ == "__main__":
    unittest.main()
