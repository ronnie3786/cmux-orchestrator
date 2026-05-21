import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from cmux_harness import orchestrator_v2_storage as v2
from cmux_harness.routes import orchestrator_v2
from cmux_harness.server import make_handler


class TestOrchestratorV2Routes(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.workspace = Path(self.tmpdir.name) / "workspace"
        self.workspace.mkdir()
        self.patch_env = patch.dict("cmux_harness.orchestrator_v2_storage.os.environ", {
            "CMUX_ORCHESTRATOR_V2_DIR": str(Path(self.tmpdir.name) / "v2-data"),
        })
        self.patch_env.start()
        self.addCleanup(self.patch_env.stop)
        self.patch_default_repo = patch("cmux_harness.orchestrator_v2_storage._default_repo", None)
        self.patch_default_repo.start()
        self.addCleanup(self.patch_default_repo.stop)
        self.cmux = Mock()
        self.cmux.create_session.return_value = {
            "workspaceId": "workspace-created",
            "surfaceId": "surface-created",
            "title": "Created shell",
            "cwd": str(self.workspace),
        }
        self.cmux.list_sessions.return_value = [
            {"workspaceId": "workspace-created", "surfaceId": "surface-created", "title": "Created shell", "cwd": str(self.workspace)},
            {"workspaceId": "loose", "surfaceId": "surface-loose", "title": "Loose shell", "cwd": str(self.workspace)},
        ]
        self.patch_cmux = patch("cmux_harness.routes.orchestrator_v2.get_cmux_cli", return_value=self.cmux)
        self.patch_cmux.start()
        self.addCleanup(self.patch_cmux.stop)

    def _make_handler(self, path, engine=None):
        handler_cls = make_handler(engine or self._engine())
        handler = handler_cls.__new__(handler_cls)
        handler.server = Mock(engine=engine or self._engine(), server_address=("0.0.0.0", 9091))
        handler.path = path
        handler.headers = {}
        handler.rfile = io.BytesIO()
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        return handler

    def _post_json(self, path, payload, engine=None):
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(path, engine=engine)
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler.do_POST()
        return handler

    def _patch_json(self, path, payload, engine=None):
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(path, engine=engine)
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler.do_PATCH()
        return handler

    def _json_body(self, handler):
        return json.loads(handler.wfile.getvalue().decode("utf-8"))

    def _engine(self):
        engine = Mock()
        engine.get_git_status_for_path.return_value = {
            "branch": "main",
            "cwd": str(self.workspace),
            "staged": [],
            "unstaged": [],
            "untracked": [],
            "commits": [],
        }
        engine._run_git_command.return_value = "diff --git a/app.py b/app.py"
        return engine

    def test_create_task_route_creates_cmux_session_and_goal_document(self):
        handler = self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Route task",
            "workspaceDir": str(self.workspace),
            "priority": "High",
            "status": "To Do",
            "sessionLaunchType": "Empty shell",
        })

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(201)
        self.assertTrue(body["ok"])
        self.assertEqual(body["task"]["title"], "Route task")
        self.assertEqual(body["task"]["cmuxSessionLinks"][0]["workspaceId"], "workspace-created")
        self.assertTrue(Path(body["task"]["goalDocument"]["path"]).exists())
        self.cmux.create_session.assert_called_once_with(title="Route task", cwd=str(self.workspace), launch_type="Empty shell")

    def test_create_task_route_rejects_missing_workspace_dir(self):
        handler = self._post_json("/api/orchestrator-v2/tasks", {
            "title": "No workspace",
            "sessionLaunchType": "Empty shell",
        })

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(400)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error"], "workspaceDir required")

    def test_create_task_from_existing_cmux_session_inherits_workspace_without_launching(self):
        handler = self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Loose shell",
            "status": "Running",
            "existingCmuxSession": {
                "workspaceId": "loose",
                "surfaceId": "surface-loose",
                "title": "Loose shell",
                "cwd": str(self.workspace),
            },
        })

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(201)
        self.assertTrue(body["ok"])
        self.assertEqual(body["task"]["workspaceDir"], str(self.workspace))
        self.assertEqual(body["task"]["cmuxSessionLinks"][0]["workspaceId"], "loose")
        self.cmux.create_session.assert_not_called()

    def test_create_task_from_existing_cmux_session_inherits_session_title(self):
        handler = self._post_json("/api/orchestrator-v2/tasks", {
            "status": "Running",
            "existingCmuxSession": {
                "workspaceId": "loose",
                "surfaceId": "surface-loose",
                "title": "Loose shell",
                "cwd": str(self.workspace),
            },
        })

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(201)
        self.assertTrue(body["ok"])
        self.assertEqual(body["task"]["title"], "Loose shell")
        self.cmux.create_session.assert_not_called()

    def test_folder_picker_route_returns_native_selection(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=f"{self.workspace}\n",
            stderr="",
        )
        with patch("cmux_harness.routes.orchestrator_v2.subprocess.run", return_value=completed) as mock_run:
            handler = self._post_json("/api/orchestrator-v2/folder-picker", {"currentPath": str(self.workspace)})

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(200)
        self.assertEqual(body["path"], str(self.workspace))
        self.assertEqual(mock_run.call_args.args[0][:2], ["osascript", "-e"])

    def test_cmux_session_input_route_sends_text_to_session(self):
        self.cmux.send_text.return_value = {"ok": True}

        handler = self._post_json("/api/orchestrator-v2/cmux/sessions/workspace-created/input", {
            "surfaceId": "surface-created",
            "text": "git status\n",
        })
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.cmux.send_text.assert_called_once_with("workspace-created", "git status\n", surface_id="surface-created")

    def test_cmux_session_input_route_sends_key_to_session(self):
        self.cmux.send_key.return_value = {"ok": True}

        handler = self._post_json("/api/orchestrator-v2/cmux/sessions/workspace-created/input", {
            "surfaceId": "surface-created",
            "key": "enter",
        })
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.cmux.send_key.assert_called_once_with("workspace-created", "enter", surface_id="surface-created")

    def test_task_goal_route_updates_markdown(self):
        created = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Goal route",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]

        handler = self._post_json(f"/api/orchestrator-v2/tasks/{created['id']}/goal", {"content": "# Updated goal"})
        goal = self._json_body(handler)["goal"]

        self.assertEqual(goal["content"], "# Updated goal")
        self.assertEqual(Path(goal["path"]).read_text(encoding="utf-8"), "# Updated goal")

    def test_attach_jira_and_pr_routes(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Links",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]

        jira_handler = self._post_json(f"/api/orchestrator-v2/tasks/{task['id']}/jira-links", {
            "key": "APP-123",
            "title": "Ticket",
            "status": "In Progress",
            "url": "https://example.atlassian.net/browse/APP-123",
        })
        pr_handler = self._post_json(f"/api/orchestrator-v2/tasks/{task['id']}/pr-links", {
            "owner": "org",
            "repo": "repo",
            "number": 42,
            "title": "Pull request",
            "url": "https://github.com/org/repo/pull/42",
            "isPrimary": True,
        })

        self.assertEqual(self._json_body(jira_handler)["jiraLink"]["key"], "APP-123")
        self.assertEqual(self._json_body(pr_handler)["pullRequestLink"]["number"], 42)

        jira_link = self._json_body(jira_handler)["jiraLink"]
        with patch("cmux_harness.routes.orchestrator_v2.find_jira_ticket", return_value={
            "key": "APP-123",
            "title": "Updated ticket",
            "status": "Selected for Development",
            "url": "https://example.atlassian.net/browse/APP-123",
        }):
            resync_handler = self._post_json(f"/api/orchestrator-v2/tasks/{task['id']}/jira-links/{jira_link['id']}/resync", {})
        resynced = self._json_body(resync_handler)["jiraLink"]
        self.assertEqual(resynced["title"], "Updated ticket")
        self.assertEqual(resynced["status"], "Selected for Development")

    def test_approval_decision_route_updates_status(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Approval task",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]
        approval_handler = self._post_json("/api/orchestrator-v2/approvals", {
            "taskId": task["id"],
            "kind": "post_jira_comment",
            "title": "Post Jira comment",
            "summary": "Preview comment body",
        })
        approval = self._json_body(approval_handler)["approval"]

        decision_handler = self._post_json(f"/api/orchestrator-v2/approvals/{approval['id']}/decision", {"status": "approved"})
        decided = self._json_body(decision_handler)["approval"]

        self.assertEqual(decided["status"], "approved")
        refreshed = v2.get_repository().get_task(task["id"])
        self.assertEqual(refreshed["pendingApprovals"], [])

    def test_orphans_route_returns_active_unlinked_cmux_sessions(self):
        self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Linked",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        })

        handler = self._make_handler("/api/orchestrator-v2/orphans")
        handler.do_GET()
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual([item["workspaceId"] for item in body["orphans"]], ["loose"])

    def test_open_pr_provider_uses_search_fields_and_includes_drafts(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps([{
                "number": 11252,
                "title": "Draft PR",
                "url": "https://github.com/doximity/iOS-Doximity/pull/11252",
                "isDraft": True,
                "state": "open",
                "author": {"login": "ronnie3786"},
                "repository": {"name": "iOS-Doximity", "nameWithOwner": "doximity/iOS-Doximity"},
            }]),
            stderr="",
        )

        with patch("cmux_harness.routes.orchestrator_v2.subprocess.run", return_value=completed) as mock_run:
            payload = orchestrator_v2.list_my_open_prs()

        args = mock_run.call_args.args[0]
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["items"][0]["number"], 11252)
        self.assertTrue(payload["items"][0]["isDraft"])
        self.assertEqual(payload["items"][0]["owner"], "doximity")
        self.assertNotIn("headRefName", args)
        self.assertIn("--limit", args)

    def test_agent_chat_answers_from_task_state_and_records_messages(self):
        self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Status source",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
            "priority": "High",
        })

        handler = self._post_json("/api/orchestrator-v2/chat", {"message": "Status source"})
        body = self._json_body(handler)

        self.assertIn("Status source is To Do", body["message"]["content"])
        messages_handler = self._make_handler("/api/orchestrator-v2/chat/messages")
        messages_handler.do_GET()
        messages = self._json_body(messages_handler)["messages"]
        self.assertEqual([message["role"] for message in messages], ["user", "assistant"])

    def test_agent_chat_extracts_jira_key_from_natural_language(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Jira linked task",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
            "jira": {"key": "APP-123", "title": "Ticket"},
        }))["task"]
        self._post_json(f"/api/orchestrator-v2/tasks/{task['id']}/summarize-sessions", {
            "sessionTexts": ["Session summary line"],
        })

        handler = self._post_json("/api/orchestrator-v2/chat", {"message": "APP-123 status"})
        body = self._json_body(handler)

        self.assertIn("Jira linked task is To Do", body["message"]["content"])
        self.assertIn("Session summary line", body["message"]["content"])

    def test_agent_tools_include_send_key_goal_read_and_not_implemented_capabilities(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Tool surface",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]
        self.cmux.send_key.return_value = {"ok": True}

        key_handler = self._post_json("/api/orchestrator-v2/agent/tools/send_cmux_key", {
            "runId": "run-tools",
            "args": {"workspaceId": "workspace-created", "surfaceId": "surface-created", "key": "enter"},
        })
        goal_handler = self._post_json("/api/orchestrator-v2/agent/tools/read_goal_markdown", {
            "runId": "run-tools",
            "args": {"taskId": task["id"]},
        })
        unsupported_handler = self._post_json("/api/orchestrator-v2/agent/tools/kill_cmux_session", {
            "runId": "run-tools",
            "args": {"workspaceId": "workspace-created"},
        })

        self.assertTrue(self._json_body(key_handler)["result"]["ok"])
        self.assertIn("Tool surface", self._json_body(goal_handler)["result"]["goal"]["content"])
        unsupported = self._json_body(unsupported_handler)["result"]
        self.assertEqual(unsupported["status"], "not_implemented")
        tool_runs = v2.get_repository().list_tool_runs(run_id="run-tools")
        self.assertIn("not_implemented", {item["status"] for item in tool_runs})

    def test_jira_comment_tool_creates_approval_and_approval_executes_stored_payload(self):
        approval_handler = self._post_json("/api/orchestrator-v2/agent/tools/post_jira_comment", {
            "runId": "run-jira",
            "args": {"key": "APP-123", "body": "Ready for review"},
        })
        approval = self._json_body(approval_handler)["result"]["approval"]

        with patch("cmux_harness.routes.orchestrator_v2.jira_routes.post_comment", return_value={"id": "comment-1"}) as mock_post:
            decision_handler = self._post_json(f"/api/orchestrator-v2/approvals/{approval['id']}/decision", {"status": "approved"})

        decided = self._json_body(decision_handler)["approval"]
        self.assertEqual(decided["status"], "approved")
        self.assertEqual(decided["execution"]["key"], "APP-123")
        mock_post.assert_called_once_with(key="APP-123", body="Ready for review")

    def test_agent_run_and_agui_event_routes_persist_contract_events(self):
        self._post_json("/api/orchestrator-v2/agent/runs", {"runId": "run-agui", "mode": "text", "input": {"message": "hi"}})
        self._post_json("/api/orchestrator-v2/agent/agui-events", {
            "runId": "run-agui",
            "events": [{"type": "RUN_STARTED", "runId": "run-agui"}],
        })
        handler = self._make_handler("/api/orchestrator-v2/agui/runs/run-agui/events")
        handler.do_GET()

        body = self._json_body(handler)
        self.assertEqual(body["events"][0]["type"], "RUN_STARTED")

    def test_voice_local_fake_pipeline_and_capabilities_are_redacted(self):
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {"CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1"}):
            transcribe = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "fixtureText": "hello from mic",
            })
            speak = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello"})

        self.assertEqual(self._json_body(transcribe)["text"], "hello from mic")
        self.assertEqual(self._json_body(speak)["provider"], "piper")

    def test_voice_provider_failures_return_json_errors(self):
        with patch("cmux_harness.orchestrator_v2_voice.speak_local_payload", side_effect=RuntimeError("Piper binary is not available")):
            handler = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello"})

        body = self._json_body(handler)
        self.assertFalse(body["ok"])
        self.assertIn("Piper binary", body["error"])

    def test_copilotkit_info_supports_rest_and_single_endpoint_shapes(self):
        get_handler = self._make_handler("/api/orchestrator-v2/copilotkit/info")
        get_handler.do_GET()
        post_handler = self._post_json("/api/orchestrator-v2/copilotkit", {"method": "info"})

        self.assertIn("default", self._json_body(get_handler)["agents"])
        self.assertIn("default", self._json_body(post_handler)["agents"])

    def test_left_rail_route_has_jira_open_draft_and_review_sections(self):
        jira_payload = [{"key": "APP-1", "title": "Ticket", "status": "To Do", "url": "https://jira.example/APP-1"}]
        gh_payload = [
            {"number": 1, "title": "Open", "url": "https://github.com/org/repo/pull/1", "isDraft": False, "repository": {"name": "repo", "owner": {"login": "org"}}},
            {"number": 2, "title": "Draft", "url": "https://github.com/org/repo/pull/2", "isDraft": True, "repository": {"name": "repo", "owner": {"login": "org"}}},
        ]
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(gh_payload), stderr="")

        with patch("cmux_harness.routes.orchestrator_v2.jira_routes.fetch_assigned_tickets", return_value=jira_payload), \
                patch("cmux_harness.routes.orchestrator_v2.subprocess.run", return_value=completed):
            handler = self._make_handler("/api/orchestrator-v2/left-rail")
            handler.do_GET()

        body = self._json_body(handler)

        self.assertEqual(body["assignedJira"]["items"][0]["key"], "APP-1")
        self.assertEqual(body["openPrs"]["items"][0]["number"], 1)
        self.assertEqual(body["draftPrs"]["items"][0]["number"], 2)
        self.assertIn("reviewRequests", body)


if __name__ == "__main__":
    unittest.main()
