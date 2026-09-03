import base64
import copy
import io
import json
import subprocess
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from herdr_harness.server import make_server
from herdr_harness.service import HerdrService


def _tiny_voice_wav() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16_000)
        audio.writeframes(b"\x00\x00" * 160)
    return buffer.getvalue()


class _SnapshotClient:
    socket_path = "/private/tmp/fake-herdr.sock"
    session = "cmux-proxy-test"

    def __init__(self, snapshot):
        self.snapshot_value = copy.deepcopy(snapshot)

    def snapshot(self):
        return copy.deepcopy(self.snapshot_value)

    def request(self, _method, _params):
        return {"type": "ok"}

    def subscribe_forever(self, *_args, **_kwargs):
        return None


class _RecordingCmuxServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _RecordingCmuxHandler)
        self.requests = []
        self.overrides = {}
        self.status_workspaces = []

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server_address[1]}/harness"


class _RecordingCmuxHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def _record(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        request = {
            "method": self.command,
            "path": parsed.path,
            "query": urllib.parse.parse_qs(parsed.query, keep_blank_values=True),
            "headers": {name.lower(): value for name, value in self.headers.items()},
            "body": body,
        }
        self.server.requests.append(request)
        return request

    def _respond(self, request):
        override = self.server.overrides.get((request["method"], request["path"]))
        if override is not None:
            if len(override) == 4:
                status, content_type, payload, response_headers = override
            else:
                status, content_type, payload = override
                response_headers = {}
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        else:
            status = 200
            content_type = "application/json"
            body = json.dumps(self._fixture(request)).encode()
            response_headers = {}
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in response_headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _fixture(self, request):
        path = request["path"]
        if path == "/api/status":
            # The real cmux status response has no top-level `ok` member.
            return {"workspaces": self.server.status_workspaces}
        if path == "/api/git-status-path":
            return {
                "ok": True,
                "branch": "codex/cmux-tools",
                "cwd": "/upstream/repo",
                "staged": [{"status": "M", "file": "Staged.swift"}],
                "unstaged": [{"status": "M", "file": "Pane.swift"}],
                "untracked": ["NewPane.swift"],
                "commits": [{"hash": "abc1234", "message": "Wire tools"}],
                "editorTargets": {"vscode": {"available": True}},
            }
        if path == "/api/git-diff-path":
            return {"ok": True, "diff": "+live upstream diff"}
        if path in {"/api/git-stage-path", "/api/git-unstage-path"}:
            return {"ok": True}
        if path == "/api/skills":
            return {
                "ok": True,
                "rootPath": "/upstream/repo",
                "skillsDirectory": ".claude/skills",
                "userSkillsDirectory": "~/.claude/skills",
                "projectSkills": [
                    {
                        "name": "swiftui-pro",
                        "skillFilePath": ".claude/skills/swiftui-pro/SKILL.md",
                        "scope": "project",
                    }
                ],
                "userSkills": [],
                "skills": [],
            }
        if path == "/api/file-search":
            return {
                "ok": True,
                "rootPath": "/upstream/repo",
                "query": "Pane",
                "files": [{"path": "Views/Pane.swift"}],
                "truncated": False,
                "limit": 12,
            }
        if path == "/api/jira/assigned":
            return {
                "ok": True,
                "project": "IOSDOX",
                "projects": ["IOSDOX"],
                "site": "jira.example.test",
                "tickets": [
                    {
                        "key": "IOSDOX-42",
                        "projectKey": "IOSDOX",
                        "title": "Wire cmux",
                        "status": "In Progress",
                        "priority": "High",
                        "issueType": "Story",
                        "url": "https://jira.example.test/browse/IOSDOX-42",
                    }
                ],
            }
        if path == "/api/jira/issue":
            return {
                "ok": True,
                "site": "jira.example.test",
                "ticket": {
                    "key": "IOSDOX-42",
                    "projectKey": "IOSDOX",
                    "title": "Wire cmux",
                    "status": "In Progress",
                    "priority": "High",
                    "issueType": "Story",
                    "url": "https://jira.example.test/browse/IOSDOX-42",
                },
            }
        if path == "/api/orchestrator-v2/left-rail/review-requests":
            return {
                "ok": True,
                "pullRequests": {
                    "ok": True,
                    "items": [
                        {
                            "number": 11856,
                            "title": "Add calculator drawer",
                            "url": "https://github.com/doximity/iOS-Doximity/pull/11856",
                            "isDraft": False,
                            "state": "open",
                            "owner": "doximity",
                            "repo": "iOS-Doximity",
                            "author": "Chandlerdea",
                        }
                    ],
                },
            }
        if path == "/api/attachments":
            return {
                "ok": True,
                "attachment": {
                    "id": "attachment-1",
                    "filename": "stored-note.txt",
                    "originalFilename": "note.txt",
                    "contentType": "text/plain",
                    "size": len(request["body"]),
                    "path": "/cmux/attachments/stored-note.txt",
                    "workspaceKey": "w1",
                    "createdAt": "2026-08-12T12:00:00Z",
                },
            }
        if path == "/api/orchestrator-v2/voice/local/transcribe":
            return {
                "ok": True,
                "text": "Review the current diff and run the focused tests.",
                "backend": "parakeet",
                "language": "en",
            }
        return {"ok": False, "error": "unhandled fake route"}

    def do_GET(self):
        self._respond(self._record())

    def do_POST(self):
        self._respond(self._record())


class HerdrCmuxProxyHTTPTests(unittest.TestCase):
    TOKEN = "herdr-secret-that-must-not-leak"

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.cmux = _RecordingCmuxServer()
        self.cmux.status_workspaces = [
            {"uuid": "cmux-live-ws", "index": 7, "cwd": str(self.root)},
            {"uuid": "cmux-live-ws", "index": 700001, "cwd": str(self.root)},
        ]
        self.cmux_thread = threading.Thread(target=self.cmux.serve_forever, daemon=True)
        self.cmux_thread.start()
        self.addCleanup(self._stop_cmux)

        snapshot = {
            "version": "0.8.0",
            "protocol": 19,
            "workspaces": [
                {
                    "workspace_id": "w1",
                    "number": 23,
                    "label": "Feature Lab",
                    "worktree": {"checkout_path": str(self.root)},
                }
            ],
            "tabs": [],
            "panes": [],
            "agents": [],
            "layouts": [],
        }
        self.service = HerdrService(
            _SnapshotClient(snapshot),
            environ={"HERDR_HARNESS_CMUX_URL": self.cmux.base_url},
        )
        self.service.refresh_snapshot()
        self.herdr = make_server(self.service, host="127.0.0.1", port=0, api_token=self.TOKEN)
        self.herdr_thread = threading.Thread(target=self.herdr.serve_forever, daemon=True)
        self.herdr_thread.start()
        self.addCleanup(self._stop_herdr)
        self.herdr_url = f"http://127.0.0.1:{self.herdr.server_address[1]}"

    def _stop_cmux(self):
        self.cmux.shutdown()
        self.cmux.server_close()
        self.cmux_thread.join(timeout=1)

    def _stop_herdr(self):
        self.herdr.shutdown()
        self.herdr.server_close()
        self.herdr_thread.join(timeout=1)

    def request(self, path, *, method="GET", payload=None, token=TOKEN):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"Authorization": f"Bearer {token}"} if token is not None else {}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.herdr_url + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    @staticmethod
    def json_body(request):
        return json.loads(request["body"])

    def test_git_routes_delegate_by_resolved_path_and_keep_herdr_contract(self):
        with self._fail_if_local_tools_run():
            status_code, status = self.request("/api/v1/workspaces/w1/git")
            diff_code, diff = self.request(
                "/api/v1/workspaces/w1/git/diff?file=Views%2FPane.swift&section=staged"
            )
            stage_code, stage = self.request(
                "/api/v1/workspaces/w1/git/stage",
                method="POST",
                payload={"file": "Views/Pane.swift"},
            )
            unstage_code, unstage = self.request(
                "/api/v1/workspaces/w1/git/unstage",
                method="POST",
                payload={"file": "Views/Pane.swift"},
            )

        self.assertEqual([status_code, diff_code, stage_code, unstage_code], [200] * 4)
        self.assertEqual(status["workspace_id"], "w1")
        self.assertEqual(status["root_path"], str(self.root.resolve()))
        self.assertNotIn("cwd", status)
        self.assertEqual(status["unstaged"], [{"status": "M", "file": "Pane.swift"}])
        self.assertEqual(diff["file"], "Views/Pane.swift")
        self.assertEqual(diff["section"], "staged")
        self.assertEqual(diff["diff"], "+live upstream diff")
        self.assertEqual(stage, {"ok": True, "workspace_id": "w1", "file": "Views/Pane.swift"})
        self.assertEqual(unstage, {"ok": True, "workspace_id": "w1", "file": "Views/Pane.swift"})

        status_request, diff_request, stage_request, unstage_request = self.cmux.requests
        self.assertEqual(
            [(item["method"], item["path"]) for item in self.cmux.requests],
            [
                ("GET", "/api/git-status-path"),
                ("POST", "/api/git-diff-path"),
                ("POST", "/api/git-stage-path"),
                ("POST", "/api/git-unstage-path"),
            ],
        )
        self.assertEqual(status_request["path"], "/api/git-status-path")
        self.assertEqual(status_request["query"], {"path": [str(self.root.resolve())]})
        self.assertEqual(self.json_body(diff_request), {
            "path": str(self.root.resolve()),
            "file": "Views/Pane.swift",
            "section": "staged",
        })
        self.assertEqual(self.json_body(stage_request), {
            "path": str(self.root.resolve()), "file": "Views/Pane.swift"
        })
        self.assertEqual(self.json_body(unstage_request), {
            "path": str(self.root.resolve()), "file": "Views/Pane.swift"
        })

    def test_git_path_and_section_validation_happens_before_proxying(self):
        with self._fail_if_local_tools_run():
            traversal_code, traversal = self.request(
                "/api/v1/workspaces/w1/git/diff?file=..%2Fsecret.txt&section=unstaged"
            )
            section_code, section = self.request(
                "/api/v1/workspaces/w1/git/diff?file=Views%2FPane.swift&section=invalid"
            )

        self.assertEqual(traversal_code, 400)
        self.assertEqual(traversal["error"]["code"], "invalid_git_path")
        self.assertEqual(section_code, 400)
        self.assertEqual(section["error"]["code"], "invalid_git_section")
        self.assertEqual(self.cmux.requests, [])

    def test_nested_pane_cwd_is_normalized_to_repository_root_for_git(self):
        nested = self.root / "Sources" / "Feature"
        nested.mkdir(parents=True)
        self.service.client.snapshot_value["workspaces"][0]["worktree"] = {}
        self.service.client.snapshot_value["panes"] = [
            {
                "pane_id": "p1",
                "workspace_id": "w1",
                "focused": True,
                "cwd": str(nested),
            }
        ]
        self.service.refresh_snapshot()

        code, _body = self.request("/api/v1/workspaces/w1/git")

        self.assertEqual(code, 200)
        self.assertEqual(
            self.cmux.requests[-1]["query"],
            {"path": [str(self.root.resolve())]},
        )

    def test_skills_files_and_jira_translate_camel_case_to_snake_case(self):
        with self._fail_if_local_tools_run():
            skills_code, skills = self.request("/api/v1/workspaces/w1/skills")
            files_code, files = self.request("/api/v1/workspaces/w1/files?q=Pane&limit=12")
            assigned_code, assigned = self.request("/api/v1/jira/assigned?project=IOSDOX&limit=7")
            issue_code, issue = self.request("/api/v1/jira/issue?q=IOSDOX-42")

        self.assertEqual([skills_code, files_code, assigned_code, issue_code], [200] * 4)
        self.assertEqual(skills["workspace_id"], "w1")
        self.assertEqual(skills["root_path"], "/upstream/repo")
        self.assertEqual(
            skills["project_skills"][0]["skill_file_path"],
            ".claude/skills/swiftui-pro/SKILL.md",
        )
        self.assertEqual(files["root_path"], "/upstream/repo")
        self.assertEqual(files["files"], [{"path": "Views/Pane.swift"}])
        self.assertEqual(assigned["tickets"][0]["project_key"], "IOSDOX")
        self.assertEqual(assigned["tickets"][0]["issue_type"], "Story")
        self.assertEqual(issue["ticket"]["project_key"], "IOSDOX")

        skills_request, files_request, assigned_request, issue_request = self.cmux.requests
        self.assertEqual(
            [(item["method"], item["path"]) for item in self.cmux.requests],
            [
                ("GET", "/api/skills"),
                ("GET", "/api/file-search"),
                ("GET", "/api/jira/assigned"),
                ("GET", "/api/jira/issue"),
            ],
        )
        self.assertEqual(skills_request["query"], {"path": [str(self.root.resolve())]})
        self.assertEqual(files_request["query"], {
            "path": [str(self.root.resolve())], "q": ["Pane"], "limit": ["12"]
        })
        self.assertEqual(assigned_request["query"], {"project": ["IOSDOX"], "limit": ["7"]})
        self.assertEqual(issue_request["query"], {"q": ["IOSDOX-42"]})

    def test_work_inbox_combines_github_and_jira_with_snake_case_contract(self):
        with self._fail_if_local_tools_run():
            code, body = self.request("/api/v1/work-inbox")

        self.assertEqual(code, 200)
        self.assertTrue(body["review_requests"]["ok"])
        self.assertEqual(body["review_requests"]["items"][0], {
            "number": 11856,
            "title": "Add calculator drawer",
            "url": "https://github.com/doximity/iOS-Doximity/pull/11856",
            "is_draft": False,
            "state": "open",
            "author": "Chandlerdea",
            "repository": "doximity/iOS-Doximity",
        })
        self.assertTrue(body["jira_tickets"]["ok"])
        self.assertEqual(body["jira_tickets"]["items"][0]["key"], "IOSDOX-42")
        self.assertEqual(
            [(item["method"], item["path"]) for item in self.cmux.requests],
            [
                ("GET", "/api/orchestrator-v2/left-rail/review-requests"),
                ("GET", "/api/jira/assigned"),
            ],
        )
        self.assertEqual(self.cmux.requests[1]["query"], {"limit": ["100"]})

    def test_work_inbox_keeps_jira_available_when_github_auth_fails(self):
        self.cmux.overrides[("GET", "/api/orchestrator-v2/left-rail/review-requests")] = (
            200,
            "application/json",
            {
                "ok": True,
                "pullRequests": {
                    "ok": False,
                    "items": [],
                    "error": "Run gh auth login.",
                },
            },
        )

        code, body = self.request("/api/v1/work-inbox")

        self.assertEqual(code, 200)
        self.assertFalse(body["review_requests"]["ok"])
        self.assertEqual(body["review_requests"]["error"], "Run gh auth login.")
        self.assertTrue(body["jira_tickets"]["ok"])
        self.assertEqual(body["jira_tickets"]["items"][0]["key"], "IOSDOX-42")

    def test_attachment_converts_base64_json_to_raw_cmux_upload_without_token(self):
        payload = b"binary\x00attachment\xff"
        with self._fail_if_local_tools_run():
            code, body = self.request(
                "/api/v1/workspaces/w1/attachments",
                method="POST",
                payload={
                    "filename": "note with spaces.txt",
                    "content_type": "text/plain",
                    "data_base64": base64.b64encode(payload).decode(),
                },
            )

        self.assertEqual(code, 200)
        self.assertEqual(body["attachment"]["original_filename"], "note.txt")
        self.assertEqual(body["attachment"]["workspace_id"], "w1")
        status_request, request = self.cmux.requests[-2:]
        self.assertEqual(status_request["path"], "/api/status")
        self.assertEqual(request["path"], "/api/attachments")
        self.assertEqual(request["body"], payload)
        self.assertEqual(request["headers"]["content-type"], "text/plain")
        self.assertEqual(
            urllib.parse.unquote(request["headers"]["x-cmux-filename"]),
            "note with spaces.txt",
        )
        self.assertEqual(
            request["headers"]["x-cmux-workspace-uuid"],
            "cmux-live-ws",
        )
        self.assertEqual(request["headers"]["x-cmux-workspace-index"], "7")
        self.assertNotIn("authorization", request["headers"])
        self.assertNotIn(self.TOKEN, repr(request))

    def test_attachment_redirect_is_rejected_without_forwarding_raw_content(self):
        sink = _RecordingCmuxServer()
        sink_thread = threading.Thread(target=sink.serve_forever, daemon=True)
        sink_thread.start()
        payload = b"raw\x00attachment\xffmust-not-leave-origin"
        sink_url = f"http://127.0.0.1:{sink.server_address[1]}/api/attachments"
        self.cmux.overrides[("POST", "/api/attachments")] = (
            307,
            "application/json",
            {"ok": False, "error": "redirect"},
            {"Location": sink_url},
        )

        try:
            code, body = self.request(
                "/api/v1/workspaces/w1/attachments",
                method="POST",
                payload={
                    "filename": "secret.bin",
                    "content_type": "application/octet-stream",
                    "data_base64": base64.b64encode(payload).decode(),
                },
            )
        finally:
            sink.shutdown()
            sink.server_close()
            sink_thread.join(timeout=1)

        self.assertEqual(code, 502)
        self.assertEqual(body["error"]["code"], "cmux_upstream_error")
        self.assertEqual(
            [(request["method"], request["path"]) for request in self.cmux.requests],
            [("GET", "/api/status"), ("POST", "/api/attachments")],
        )
        self.assertEqual(self.cmux.requests[-1]["body"], payload)
        self.assertEqual(sink.requests, [])

    def test_attachment_requires_one_unambiguous_live_cmux_workspace(self):
        cases = (
            ([], 404, "cmux_workspace_not_found"),
            (
                [
                    {"uuid": "cmux-one", "index": 1, "cwd": str(self.root)},
                    {"uuid": "cmux-two", "index": 2, "cwd": str(self.root)},
                ],
                409,
                "cmux_workspace_ambiguous",
            ),
        )
        for workspaces, expected_status, expected_code in cases:
            with self.subTest(code=expected_code):
                self.cmux.status_workspaces = workspaces
                code, body = self.request(
                    "/api/v1/workspaces/w1/attachments",
                    method="POST",
                    payload={
                        "filename": "note.txt",
                        "content_type": "text/plain",
                        "data_base64": base64.b64encode(b"hello").decode(),
                    },
                )
                self.assertEqual(code, expected_status)
                self.assertEqual(body["error"]["code"], expected_code)
                self.assertEqual(self.cmux.requests[-1]["path"], "/api/status")

    def test_upstream_4xx_is_safe_and_does_not_leak_body_or_url(self):
        self.cmux.overrides[("GET", "/api/git-status-path")] = (
            404,
            "application/json",
            {"ok": False, "error": "workspace not found", "secret": "do-not-leak"},
        )
        code, body = self.request("/api/v1/workspaces/w1/git")

        self.assertEqual(code, 404)
        self.assertEqual(body["error"]["message"], "workspace not found")
        self.assertNotIn("do-not-leak", json.dumps(body))
        self.assertNotIn(self.cmux.base_url, json.dumps(body))

    def test_upstream_5xx_and_unreachable_are_stable_safe_errors(self):
        self.cmux.overrides[("GET", "/api/jira/assigned")] = (
            500,
            "text/html",
            b"<html>super-secret crash dump</html>",
        )
        upstream_code, upstream_body = self.request("/api/v1/jira/assigned")

        self.assertEqual(upstream_code, 502)
        self.assertEqual(upstream_body["error"]["code"], "cmux_upstream_error")
        self.assertNotIn("super-secret", json.dumps(upstream_body))

        self.service.cmux_tools.base_url = "http://127.0.0.1:1"
        unavailable_code, unavailable_body = self.request("/api/v1/jira/assigned")
        self.assertEqual(unavailable_code, 503)
        self.assertEqual(unavailable_body["error"]["code"], "cmux_unavailable")
        self.assertNotIn("127.0.0.1", json.dumps(unavailable_body))

    def test_proxy_routes_still_require_herdr_bearer_auth(self):
        code, body = self.request("/api/v1/workspaces/w1/git", token=None)
        self.assertEqual(code, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")
        self.assertEqual(self.cmux.requests, [])

    def test_voice_transcription_uses_authenticated_bounded_cmux_proxy(self):
        wav = _tiny_voice_wav()
        code, body = self.request(
            "/api/v1/voice/transcriptions",
            method="POST",
            payload={
                "filename": "ramble.wav",
                "mime_type": "audio/wav",
                "data_base64": base64.b64encode(wav).decode(),
            },
        )

        self.assertEqual(code, 200)
        self.assertEqual(body["text"], "Review the current diff and run the focused tests.")
        self.assertEqual(body["backend"], "parakeet")
        request = self.cmux.requests[-1]
        self.assertEqual(request["path"], "/api/orchestrator-v2/voice/local/transcribe")
        upstream = self.json_body(request)
        self.assertEqual(base64.b64decode(upstream["audioBase64"]), wav)
        self.assertEqual(upstream["backend"], "parakeet")
        self.assertFalse(upstream["appendChat"])
        self.assertNotIn("authorization", request["headers"])
        self.assertNotIn(self.TOKEN, repr(request))

    def test_voice_transcription_rejects_non_wav_before_proxying(self):
        code, body = self.request(
            "/api/v1/voice/transcriptions",
            method="POST",
            payload={
                "filename": "ramble.wav",
                "mime_type": "audio/wav",
                "data_base64": base64.b64encode(b"not a wav").decode(),
            },
        )

        self.assertEqual(code, 400)
        self.assertEqual(body["error"]["code"], "invalid_voice_recording")
        self.assertEqual(self.cmux.requests, [])

    def test_voice_transcription_rejects_multipart_filename_injection(self):
        wav = _tiny_voice_wav()
        code, body = self.request(
            "/api/v1/voice/transcriptions",
            method="POST",
            payload={
                "filename": "voice.wav\r\nX-Leak: yes.wav",
                "mime_type": "audio/wav",
                "data_base64": base64.b64encode(wav).decode(),
            },
        )

        self.assertEqual(code, 400)
        self.assertEqual(body["error"]["code"], "invalid_voice_recording")
        self.assertEqual(self.cmux.requests, [])

    @staticmethod
    def _fail_if_local_tools_run():
        return _NoLocalToolCalls()


class _NoLocalToolCalls:
    def __enter__(self):
        self.stack = [
            patch("herdr_harness.workspace_tools._run", side_effect=AssertionError("local workspace tool executed")),
        ]
        for item in self.stack:
            item.start()
        return self

    def __exit__(self, exc_type, exc, traceback):
        for item in reversed(self.stack):
            item.stop()
        return False


if __name__ == "__main__":
    unittest.main()
