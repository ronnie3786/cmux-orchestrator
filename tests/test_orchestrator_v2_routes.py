import http.client
import io
import json
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

from cmux_harness import orchestrator_v2_runtime
from cmux_harness import orchestrator_v2_storage as v2
from cmux_harness import orchestrator_v2_voice
from cmux_harness.engine import HarnessEngine
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
        self.cmux.create_session_with_command.return_value = {
            "workspaceId": "review-workspace",
            "surfaceId": "review-surface",
            "title": "PR-Review-11244",
            "cwd": str(self.workspace),
            "launchType": "Codex",
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
        engine._git_action_paths.side_effect = lambda _cwd, file, *, stage: [file]
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

    def test_git_stage_route_runs_git_add_for_workspace_path(self):
        engine = self._engine()
        engine._run_git_command.return_value = ""

        handler = self._post_json("/api/orchestrator-v2/git/stage", {
            "path": str(self.workspace),
            "file": "src/app.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["action"], "stage")
        engine._run_git_command.assert_called_once_with(str(self.workspace.resolve()), ["add", "--", "src/app.py"])

    def test_git_unstage_route_runs_git_reset_for_workspace_path(self):
        engine = self._engine()
        engine._run_git_command.return_value = ""

        handler = self._post_json("/api/orchestrator-v2/git/unstage", {
            "path": str(self.workspace),
            "file": "src/app.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["action"], "unstage")
        engine._run_git_command.assert_called_once_with(str(self.workspace.resolve()), ["reset", "--", "src/app.py"])

    def test_git_stage_route_expands_unstaged_rename_paths(self):
        engine = self._engine()
        engine._run_git_command.return_value = ""
        engine._git_action_paths.side_effect = None
        engine._git_action_paths.return_value = ["src/old.py", "src/new.py"]

        handler = self._post_json("/api/orchestrator-v2/git/stage", {
            "path": str(self.workspace),
            "file": "src/new.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        engine._run_git_command.assert_called_once_with(
            str(self.workspace.resolve()),
            ["add", "--", "src/old.py", "src/new.py"],
        )

    def test_git_unstage_route_expands_staged_rename_paths(self):
        engine = self._engine()
        engine._run_git_command.return_value = ""
        engine._git_action_paths.side_effect = None
        engine._git_action_paths.return_value = ["src/old.py", "src/new.py"]

        handler = self._post_json("/api/orchestrator-v2/git/unstage", {
            "path": str(self.workspace),
            "file": "src/new.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        engine._run_git_command.assert_called_once_with(
            str(self.workspace.resolve()),
            ["reset", "--", "src/old.py", "src/new.py"],
        )

    def test_git_diff_route_expands_untracked_directory(self):
        untracked_dir = self.workspace / "notes"
        untracked_dir.mkdir()
        (untracked_dir / "a.txt").write_text("A", encoding="utf-8")
        (untracked_dir / "b.txt").write_text("B", encoding="utf-8")
        engine = self._engine()
        engine._run_git_command.side_effect = ["diff a", "diff b"]

        handler = self._post_json("/api/orchestrator-v2/git/diff", {
            "path": str(self.workspace),
            "file": "notes",
            "section": "untracked",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertEqual(body["diff"], "diff a\ndiff b")
        self.assertEqual(engine._run_git_command.call_args_list[0].args[1], ["diff", "--no-index", "--", "/dev/null", "notes/a.txt"])
        self.assertEqual(engine._run_git_command.call_args_list[1].args[1], ["diff", "--no-index", "--", "/dev/null", "notes/b.txt"])

    def test_git_commit_files_route_returns_changed_files(self):
        engine = self._engine()
        engine._run_git_command.return_value = (
            "M\0src/app.py\0A\0tests/test_app.py\0R100\0old.py\0new.py\0"
        )
        engine._parse_git_name_status_z.side_effect = HarnessEngine._parse_git_name_status_z

        handler = self._post_json("/api/orchestrator-v2/git/commit-files", {
            "path": str(self.workspace),
            "hash": "abc1234",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["files"], [
            {"status": "M", "file": "src/app.py"},
            {"status": "A", "file": "tests/test_app.py"},
            {"status": "R100", "file": "new.py", "previousFile": "old.py"},
        ])
        engine._run_git_command.assert_called_once_with(
            str(self.workspace.resolve()),
            [
                "diff-tree",
                "--diff-merges=first-parent",
                "--root",
                "--no-commit-id",
                "--name-status",
                "-r",
                "-z",
                "abc1234",
            ],
        )

    def test_git_commit_files_route_rejects_invalid_hash(self):
        engine = self._engine()

        handler = self._post_json("/api/orchestrator-v2/git/commit-files", {
            "path": str(self.workspace),
            "hash": "abc1234;rm",
        }, engine=engine)
        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(400)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error"], "invalid hash")
        engine._run_git_command.assert_not_called()

    def test_git_commit_diff_route_returns_file_diff(self):
        engine = self._engine()
        engine._run_git_command.return_value = "diff --git a/src/app.py b/src/app.py"

        handler = self._post_json("/api/orchestrator-v2/git/commit-diff", {
            "path": str(self.workspace),
            "hash": "abc1234",
            "file": "src/app.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertEqual(body["diff"], "diff --git a/src/app.py b/src/app.py")
        engine._run_git_command.assert_called_once_with(
            str(self.workspace.resolve()),
            ["diff", "abc1234~1", "abc1234", "--", "src/app.py"],
            max_bytes=50 * 1024,
        )

    def test_git_commit_diff_route_falls_back_to_show_for_root_commit(self):
        engine = self._engine()
        engine._run_git_command.side_effect = ["[error] bad revision", "root commit diff"]

        handler = self._post_json("/api/orchestrator-v2/git/commit-diff", {
            "path": str(self.workspace),
            "hash": "abc1234",
            "file": "src/app.py",
        }, engine=engine)
        body = self._json_body(handler)

        self.assertEqual(body["diff"], "root commit diff")
        self.assertEqual(engine._run_git_command.call_args_list[0].args[1], ["diff", "abc1234~1", "abc1234", "--", "src/app.py"])
        self.assertEqual(engine._run_git_command.call_args_list[1].args[1], ["show", "abc1234", "--", "src/app.py"])

    def test_open_in_native_route_resolves_workspace_file(self):
        target = self.workspace / "src" / "app.py"
        target.parent.mkdir()
        target.write_text("print('hi')", encoding="utf-8")

        with patch("cmux_harness.routes.orchestrator_v2.subprocess.run") as mock_run:
            handler = self._post_json("/api/orchestrator-v2/open-in-native", {
                "path": str(self.workspace),
                "file": "src/app.py",
            })
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["path"], str(target.resolve()))
        mock_run.assert_called_once_with(["open", str(target.resolve())], check=True, capture_output=True, text=True)

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
            "key": "backspace",
        })
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.cmux.send_key.assert_called_once_with("workspace-created", "backspace", surface_id="surface-created")

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
        unsupported_handler = self._post_json("/api/orchestrator-v2/agent/tools/post_pr_reply", {
            "runId": "run-tools",
            "args": {},
        })

        self.assertTrue(self._json_body(key_handler)["result"]["ok"])
        self.assertIn("Tool surface", self._json_body(goal_handler)["result"]["goal"]["content"])
        unsupported = self._json_body(unsupported_handler)["result"]
        self.assertEqual(unsupported["status"], "not_implemented")
        tool_runs = v2.get_repository().list_tool_runs(run_id="run-tools")
        self.assertIn("not_implemented", {item["status"] for item in tool_runs})

    def test_kill_cmux_session_tool_creates_approval_and_executes_on_approve(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Lifecycle task",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]
        self.cmux.close_session.return_value = {"ok": True, "workspaceId": "workspace-created"}

        approval_handler = self._post_json("/api/orchestrator-v2/agent/tools/kill_cmux_session", {
            "runId": "run-lifecycle",
            "args": {"workspaceId": "workspace-created", "taskId": task["id"]},
        })
        approval = self._json_body(approval_handler)["result"]["approval"]

        self.assertEqual(approval["kind"], "kill_cmux_session")
        self.assertEqual(approval["status"], "pending")
        self.assertEqual(approval["payload"]["workspaceId"], "workspace-created")
        self.cmux.close_session.assert_not_called()

        decision_handler = self._post_json(
            f"/api/orchestrator-v2/approvals/{approval['id']}/decision", {"status": "approved"}
        )
        decided = self._json_body(decision_handler)["approval"]
        self.assertEqual(decided["status"], "approved")
        self.assertEqual(decided["execution"]["tool"], "kill_cmux_session")
        self.cmux.close_session.assert_called_once_with("workspace-created")

    def test_denied_kill_approval_never_executes(self):
        approval_handler = self._post_json("/api/orchestrator-v2/agent/tools/kill_cmux_session", {
            "runId": "run-denied",
            "args": {"workspaceId": "workspace-created"},
        })
        approval = self._json_body(approval_handler)["result"]["approval"]

        decision_handler = self._post_json(
            f"/api/orchestrator-v2/approvals/{approval['id']}/decision", {"status": "denied"}
        )
        decided = self._json_body(decision_handler)["approval"]
        self.assertEqual(decided["status"], "denied")
        self.assertNotIn("execution", decided)
        self.cmux.close_session.assert_not_called()

    def test_direct_kill_route_closes_session_and_detaches_task_link(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Kill me",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        }))["task"]
        self.cmux.close_session.return_value = {"ok": True, "workspaceId": "workspace-created"}

        handler = self._post_json("/api/orchestrator-v2/cmux/sessions/workspace-created/kill", {})
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["taskId"], task["id"])
        self.cmux.close_session.assert_called_once_with("workspace-created")
        refreshed = v2.get_repository().get_task(task["id"])
        self.assertEqual(refreshed["cmuxSessionLinks"], [])

    def test_direct_restart_route_recreates_session_and_relinks_task(self):
        task = self._json_body(self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Restart me",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Claude Code",
        }))["task"]
        self.cmux.restart_session.return_value = {
            "ok": True,
            "closed": {"ok": True},
            "session": {
                "workspaceId": "workspace-restarted",
                "surfaceId": "surface-restarted",
                "title": "Restart me",
                "cwd": str(self.workspace),
            },
            "previousWorkspaceId": "workspace-created",
        }

        handler = self._post_json("/api/orchestrator-v2/cmux/sessions/workspace-created/restart", {})
        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["session"]["workspaceId"], "workspace-restarted")
        self.cmux.restart_session.assert_called_once()
        _, kwargs = self.cmux.restart_session.call_args
        self.assertEqual(kwargs["launch_type"], "Claude Code")
        refreshed = v2.get_repository().get_task(task["id"])
        self.assertEqual(refreshed["cmuxSessionLinks"][0]["workspaceId"], "workspace-restarted")

    def test_events_token_route_changes_after_state_mutation(self):
        first = self._json_body(self._make_handler_get("/api/orchestrator-v2/events/token"))["token"]
        self._post_json("/api/orchestrator-v2/tasks", {
            "title": "Token task",
            "workspaceDir": str(self.workspace),
            "sessionLaunchType": "Empty shell",
        })
        second = self._json_body(self._make_handler_get("/api/orchestrator-v2/events/token"))["token"]
        self.assertNotEqual(first, second)

    def _make_handler_get(self, path):
        handler = self._make_handler(path)
        handler.do_GET()
        return handler

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
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1",
            "ORCHESTRATOR_V2_TTS_BACKEND": "",
        }):
            transcribe = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "fixtureText": "hello from mic",
            })
            speak = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello"})
            piper_speak = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello", "provider": "piper"})

        self.assertEqual(self._json_body(transcribe)["text"], "hello from mic")
        self.assertEqual(self._json_body(speak)["provider"], "kokoro")
        self.assertEqual(self._json_body(piper_speak)["provider"], "piper")

    def test_voice_transcribe_route_skips_chat_append_for_append_chat_false_and_partial(self):
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {"CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1"}):
            no_append = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "backend": "parakeet",
                "appendChat": False,
                "fixtureText": "list my sessions",
            })
            partial = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "backend": "parakeet",
                "partial": True,
                "fixtureText": "list my ses",
            })

        self.assertEqual(self._json_body(no_append)["text"], "list my sessions")
        self.assertFalse(self._json_body(no_append)["partial"])
        self.assertTrue(self._json_body(partial)["partial"])
        self.assertEqual(v2.get_repository().list_chat_messages(), [])

    def test_voice_transcribe_rejects_oversized_json_before_reading_body(self):
        handler = self._make_handler("/api/orchestrator-v2/voice/local/transcribe")
        handler.headers = {
            "Content-Length": str(orchestrator_v2_voice.MAX_STT_JSON_BYTES + 1)
        }
        handler.rfile = MagicMock()

        handler.do_POST()

        handler.rfile.read.assert_not_called()
        handler.send_response.assert_called_once_with(413)
        self.assertIn("size limit", self._json_body(handler)["error"])

    def _fake_whisper_module(self, transcript):
        segment = MagicMock()
        segment.text = transcript
        info = MagicMock()
        info.language = "en"
        fake_model = MagicMock()
        fake_model.transcribe.return_value = ([segment], info)
        fake_module = MagicMock()
        fake_module.WhisperModel.return_value = fake_model
        return fake_module

    def test_voice_transcribe_webm_payload_skips_parakeet_and_uses_faster_whisper(self):
        fake_module = self._fake_whisper_module(" hello from webm ")
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "",
            "ORCHESTRATOR_V2_STT_BACKEND": "parakeet",
        }), patch.dict("sys.modules", {"faster_whisper": fake_module}), \
                patch("cmux_harness.orchestrator_v2_voice._transcribe_parakeet") as mock_parakeet:
            handler = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "filename": "voice.webm",
                "mimeType": "audio/webm",
                "appendChat": False,
            })

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertEqual(body["backend"], "faster-whisper")
        self.assertEqual(body["text"], "hello from webm")
        mock_parakeet.assert_not_called()

    def test_voice_transcribe_parakeet_http_error_falls_back_to_faster_whisper(self):
        fake_module = self._fake_whisper_module("fallback transcript")
        http_error = urllib.error.HTTPError("http://parakeet/transcribe", 500, "boom", {}, None)
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "",
            "ORCHESTRATOR_V2_STT_BACKEND": "parakeet",
        }), patch.dict("sys.modules", {"faster_whisper": fake_module}), \
                patch("cmux_harness.orchestrator_v2_voice._transcribe_parakeet", side_effect=http_error) as mock_parakeet:
            handler = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "filename": "voice.wav",
                "appendChat": False,
            })

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertEqual(body["backend"], "faster-whisper")
        self.assertEqual(body["text"], "fallback transcript")
        mock_parakeet.assert_called_once()

    def test_voice_transcribe_parakeet_http_exception_falls_back_to_faster_whisper(self):
        fake_module = self._fake_whisper_module("recovered transcript")
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "",
            "ORCHESTRATOR_V2_STT_BACKEND": "parakeet",
        }), patch.dict("sys.modules", {"faster_whisper": fake_module}), \
                patch("cmux_harness.orchestrator_v2_voice._transcribe_parakeet", side_effect=http.client.IncompleteRead(b"partial")):
            handler = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "filename": "voice.wav",
                "appendChat": False,
            })

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertEqual(body["backend"], "faster-whisper")

    def test_voice_transcribe_parakeet_http_error_without_whisper_reports_both_errors(self):
        http_error = urllib.error.HTTPError("http://parakeet/transcribe", 502, "bad gateway", {}, None)
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "",
            "ORCHESTRATOR_V2_STT_BACKEND": "parakeet",
        }), patch.dict("sys.modules", {"faster_whisper": None}), \
                patch("cmux_harness.orchestrator_v2_voice._transcribe_parakeet", side_effect=http_error):
            handler = self._post_json("/api/orchestrator-v2/voice/local/transcribe", {
                "audioBase64": "AA==",
                "filename": "voice.wav",
                "appendChat": False,
            })

        body = self._json_body(handler)
        self.assertFalse(body["ok"])
        self.assertIn("HTTP 502", body["error"])
        self.assertIn("faster-whisper", body["error"])

    def test_parakeet_transcription_uses_no_redirect_opener_and_bounds_response(self):
        response = MagicMock()
        response.headers = {"Content-Length": "25"}
        response.read.return_value = b'{"text":"private transcript"}'
        context = MagicMock()
        context.__enter__.return_value = response

        with patch.object(
            orchestrator_v2_voice._NO_REDIRECT_OPENER,
            "open",
            return_value=context,
        ) as open_request, patch(
            "cmux_harness.orchestrator_v2_voice.urllib.request.urlopen"
        ) as default_open:
            text = orchestrator_v2_voice._transcribe_parakeet(
                orchestrator_v2_voice._tiny_wav_bytes(),
                "voice.wav",
            )

        self.assertEqual(text, "private transcript")
        open_request.assert_called_once()
        default_open.assert_not_called()
        response.read.assert_called_once_with(orchestrator_v2_voice.MAX_STT_RESPONSE_BYTES + 1)

    def test_parakeet_transcription_rejects_oversized_declared_response(self):
        response = MagicMock()
        response.headers = {
            "Content-Length": str(orchestrator_v2_voice.MAX_STT_RESPONSE_BYTES + 1)
        }
        context = MagicMock()
        context.__enter__.return_value = response

        with patch.object(
            orchestrator_v2_voice._NO_REDIRECT_OPENER,
            "open",
            return_value=context,
        ):
            with self.assertRaisesRegex(ValueError, "size limit"):
                orchestrator_v2_voice._transcribe_parakeet(
                    orchestrator_v2_voice._tiny_wav_bytes(),
                    "voice.wav",
                )

        response.read.assert_not_called()

    def test_proxy_stream_forwards_sse_heartbeat_bytes_unmodified(self):
        chunks = [b": ping\n\n", b"data: {\"type\":\"RUN_FINISHED\"}\n\n"]
        response = MagicMock()
        response.status = 200
        response.headers = {"Content-Type": "text/event-stream; charset=utf-8"}
        response.read.side_effect = chunks + [b""]
        handler = self._make_handler("/api/orchestrator-v2/agent/chat")

        with patch("cmux_harness.orchestrator_v2_runtime.urllib.request.urlopen", return_value=response):
            result = orchestrator_v2_runtime.proxy_stream(handler, "/api/orchestrator-v2/agent/chat", {})

        self.assertTrue(result)
        self.assertEqual(handler.wfile.getvalue(), b"".join(chunks))
        response.close.assert_called_once()

    def test_proxy_stream_closes_upstream_when_client_disconnects_mid_heartbeat(self):
        response = MagicMock()
        response.status = 200
        response.headers = {"Content-Type": "text/event-stream; charset=utf-8"}
        response.read.return_value = b": ping\n\n"
        handler = self._make_handler("/api/orchestrator-v2/agent/chat")
        handler.wfile = Mock()
        handler.wfile.write.side_effect = BrokenPipeError()

        with patch("cmux_harness.orchestrator_v2_runtime.urllib.request.urlopen", return_value=response):
            result = orchestrator_v2_runtime.proxy_stream(handler, "/api/orchestrator-v2/agent/chat", {})

        self.assertTrue(result)
        response.close.assert_called_once()

    def test_voice_speak_fake_kokoro_returns_wav_payload(self):
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1",
            "ORCHESTRATOR_V2_KOKORO_VOICE": "",
        }):
            handler = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello", "provider": "kokoro"})

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertEqual(body["provider"], "kokoro")
        self.assertEqual(body["mimeType"], "audio/wav")
        self.assertEqual(body["voice"], "bm_daniel")
        self.assertTrue(body["audioBase64"])
        self.assertIn("elapsedS", body)

    def test_voice_speak_truncates_long_text_at_sentence_boundary_instead_of_erroring(self):
        long_text = "This answer keeps going with plenty of detail. " * 40
        fake_result = {"ok": True, "provider": "kokoro", "mimeType": "audio/wav", "audioBase64": "AA=="}
        with patch("cmux_harness.orchestrator_v2_voice._speak_kokoro", return_value=fake_result) as mock_speak:
            handler = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": long_text, "provider": "kokoro"})

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertTrue(body["truncated"])
        spoken = mock_speak.call_args[0][0]
        self.assertLessEqual(len(spoken), 1200)
        self.assertTrue(spoken.endswith("."))

    def test_voice_speak_truncates_unbroken_long_text_and_short_text_has_no_flag(self):
        with patch.dict("cmux_harness.orchestrator_v2_voice.os.environ", {"CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1"}):
            long_handler = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "x" * 2000, "provider": "kokoro"})
            short_handler = self._post_json("/api/orchestrator-v2/voice/local/speak", {"text": "hello", "provider": "kokoro"})

        long_body = self._json_body(long_handler)
        self.assertTrue(long_body["ok"])
        self.assertTrue(long_body["truncated"])
        short_body = self._json_body(short_handler)
        self.assertTrue(short_body["ok"])
        self.assertNotIn("truncated", short_body)

    def test_voice_enrich_fake_returns_html_panel(self):
        with patch.dict("cmux_harness.orchestrator_v2_enrich.os.environ", {"CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "1"}):
            handler = self._post_json("/api/orchestrator-v2/voice/enrich", {
                "question": "What sessions are running?",
                "answer": "Two sessions are running.",
                "toolResults": [{"name": "list_cmux_sessions", "preview": "2 sessions"}],
                "title": "Cmux sessions",
            })

        body = self._json_body(handler)
        self.assertTrue(body["ok"])
        self.assertIn("<html", body["html"].lower())
        self.assertIn("</html>", body["html"].lower())
        self.assertNotIn("<script", body["html"].lower())
        self.assertIn("model", body)
        self.assertIn("elapsedS", body)

    def test_voice_enrich_rejects_script_html_with_502(self):
        bad_html = (
            "<html><head><style>body{background:#0f1524}</style></head><body>"
            + "<p>" + "detail " * 80 + "</p>"
            + "<script>alert(1)</script></body></html>"
        )
        response = MagicMock()
        response.read.return_value = json.dumps({"choices": [{"message": {"content": bad_html}}]}).encode("utf-8")
        response.__enter__.return_value = response

        with patch.dict("cmux_harness.orchestrator_v2_enrich.os.environ", {
            "CMUX_ORCHESTRATOR_V2_FAKE_VOICE": "",
            "FIREWORKS_API_KEY": "fw_test_1234567890abcdef",
        }), patch("cmux_harness.orchestrator_v2_enrich.urllib.request.urlopen", return_value=response):
            handler = self._post_json("/api/orchestrator-v2/voice/enrich", {"question": "q", "answer": "a"})

        body = self._json_body(handler)
        handler.send_response.assert_called_once_with(502)
        self.assertFalse(body["ok"])
        self.assertIn("forbidden", body["error"])

    def test_capabilities_payload_reports_visual_voice_fields(self):
        handler = self._make_handler_get("/api/orchestrator-v2/ai/capabilities")
        body = self._json_body(handler)

        voice_modes = body["voiceModes"]
        self.assertIsInstance(voice_modes["visual"], bool)
        local = voice_modes["local"]
        self.assertIn("backend", local["stt"])
        self.assertIn("available", local["stt"])
        self.assertIn("provider", local["tts"])
        self.assertIn("available", local["tts"])
        self.assertIsInstance(local["enrich"], bool)
        self.assertIn("parakeet", body["health"]["checks"])
        self.assertIn("kokoro", body["health"]["checks"])

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

    def test_pr_review_requests_route_lists_ios_review_requests(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps([{
                "number": 11244,
                "title": "Review target",
                "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
                "headRefName": "feature/review-target",
                "isDraft": False,
                "state": "OPEN",
                "author": {"login": "teammate"},
            }]),
            stderr="",
        )

        with patch("cmux_harness.pr_review_orchestrator.subprocess.run", return_value=completed) as mock_run:
            handler = self._make_handler("/api/orchestrator-v2/pr-reviews/review-requests?repo=doximity/iOS-Doximity")
            handler.do_GET()

        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["repository"], "doximity/iOS-Doximity")
        self.assertEqual(body["items"][0]["number"], 11244)
        self.assertEqual(body["items"][0]["owner"], "doximity")
        self.assertEqual(body["items"][0]["repo"], "iOS-Doximity")
        command = mock_run.call_args.args[0]
        self.assertEqual(command[1:4], ["pr", "list", "--search"])
        self.assertIn("--repo", command)
        self.assertIn("doximity/iOS-Doximity", command)

    def test_start_pr_review_route_launches_codex_workspace_and_creates_task(self):
        handler = self._post_json("/api/orchestrator-v2/pr-reviews/start", {
            "repo": "doximity/iOS-Doximity",
            "number": 11244,
            "projectDir": str(self.workspace),
            "pullRequest": {
                "number": 11244,
                "title": "Review target",
                "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
                "branch": "feature/review-target",
                "state": "OPEN",
            },
        })

        body = self._json_body(handler)

        handler.send_response.assert_called_once_with(201)
        self.assertTrue(body["ok"])
        self.assertEqual(body["prompt"], "$ios-review-remote-pr 11244")
        self.assertEqual(body["task"]["status"], "Running")
        self.assertEqual(body["task"]["pullRequestLinks"][0]["number"], 11244)
        self.assertEqual(body["task"]["cmuxSessionLinks"][0]["workspaceId"], "review-workspace")
        kwargs = self.cmux.create_session_with_command.call_args.kwargs
        self.assertEqual(kwargs["title"], "PR-Review-11244")
        self.assertEqual(kwargs["cwd"], str(self.workspace.resolve()))
        self.assertEqual(kwargs["launch_type"], "Codex")
        self.assertIn("$ios-review-remote-pr 11244", kwargs["command"])
        self.assertIn("--no-alt-screen", kwargs["command"])

    def test_start_pr_review_agent_tool_records_tool_run(self):
        handler = self._post_json("/api/orchestrator-v2/agent/tools/start_pr_review", {
            "runId": "run-pr-review",
            "args": {
                "repo": "doximity/iOS-Doximity",
                "number": 11244,
                "projectDir": str(self.workspace),
                "pullRequest": {
                    "number": 11244,
                    "title": "Review target",
                    "url": "https://github.com/doximity/iOS-Doximity/pull/11244",
                },
            },
        })

        body = self._json_body(handler)

        self.assertTrue(body["ok"])
        self.assertEqual(body["result"]["pullRequest"]["number"], 11244)
        tool_runs = v2.get_repository().list_tool_runs(run_id="run-pr-review")
        self.assertEqual(tool_runs[0]["toolName"], "start_pr_review")


if __name__ == "__main__":
    unittest.main()
