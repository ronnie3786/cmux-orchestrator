import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

from cmux_harness import objectives
from cmux_harness.orchestrator import Orchestrator
from cmux_harness import workspaces
from cmux_harness.server import make_handler

REAL_SUBPROCESS_RUN = subprocess.run


class _BrokenPipeStream:
    def write(self, _body):
        raise BrokenPipeError


class TestServerResponses(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.workspaces_dir = Path(self.tmpdir.name) / "workspaces"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.patch_workspaces_dir = patch.object(workspaces, "WORKSPACES_DIR", self.workspaces_dir)
        self.patch_workspaces_dir.start()
        self.addCleanup(self.patch_workspaces_dir.stop)
        self.patch_subprocess_run = patch("cmux_harness.objectives.subprocess.run")
        self.mock_run = self.patch_subprocess_run.start()
        self.mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        self.addCleanup(self.patch_subprocess_run.stop)
        self.mock_workspace_run = self.mock_run

    def test_json_response_suppresses_broken_pipe(self):
        handler_cls = make_handler(Mock())
        handler = handler_cls.__new__(handler_cls)
        handler.wfile = _BrokenPipeStream()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()

        handler._json_response({"ok": True}, status=202)

        handler.send_response.assert_called_once_with(202)
        handler.end_headers.assert_called_once()

    def test_json_response_suppresses_broken_pipe_during_headers(self):
        handler_cls = make_handler(Mock())
        handler = handler_cls.__new__(handler_cls)
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock(side_effect=BrokenPipeError)

        result = handler._json_response({"ok": True}, status=202)

        self.assertFalse(result)
        handler.send_response.assert_called_once_with(202)
        handler.end_headers.assert_called_once()

    def test_json_response_writes_body_when_pipe_is_open(self):
        handler_cls = make_handler(Mock())
        handler = handler_cls.__new__(handler_cls)
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()

        handler._json_response({"ok": True})

        self.assertEqual(handler.wfile.getvalue(), b'{"ok": true}')

    def _make_handler(self, engine, path):
        handler_cls = make_handler(engine)
        handler = handler_cls.__new__(handler_cls)
        handler.server = Mock(engine=engine)
        handler.path = path
        handler.headers = {}
        handler.rfile = io.BytesIO()
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        return handler

    def _create_objective_with_worktree(self, worktree_path=None):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        if worktree_path is not None:
            objectives.update_objective(objective["id"], {"worktreePath": str(worktree_path)})
            objective = objectives.read_objective(objective["id"])
        return objective

    def _create_project(self, name="Server Project", root_path=None, default_base_branch="main"):
        root = Path(root_path) if root_path is not None else (Path(self.tmpdir.name) / name.lower().replace(" ", "-"))
        root.mkdir(parents=True, exist_ok=True)
        return objectives.create_project(name, str(root), default_base_branch)

    def _create_workspace(self, root_path=None, project=None, name="Workspace"):
        root = Path(root_path) if root_path is not None else (Path(self.tmpdir.name) / name.lower().replace(" ", "-"))
        root.mkdir(parents=True, exist_ok=True)
        project = project or self._create_project(root_path=root)
        return workspaces.create_workspace_session(project["id"], str(root), name=name)

    def _write_build_log(self, objective, lines, filename="build.log"):
        log_path = Path(objective["worktreePath"]) / ".build" / filename
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return log_path

    def _write_console_log(self, objective, filename, lines):
        log_path = Path(objective["worktreePath"]) / ".build" / "logs" / filename
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return log_path

    def _post_json(self, path, payload, engine=None):
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine or Mock(), path)
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)
        handler.do_POST()
        return handler

    def _run_git_command(self, cwd, args, max_bytes=None):
        if not cwd:
            return ""
        try:
            if not os.path.isdir(cwd):
                return f"[error] cwd not found: {cwd}"
            result = REAL_SUBPROCESS_RUN(
                ["git"] + args,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            return f"[error] git {' '.join(args)} timed out after 10s"
        except OSError as exc:
            return f"[error] git {' '.join(args)} failed: {exc}"

        output = result.stdout or ""
        if result.returncode != 0:
            err = (result.stderr or "").strip()
            if err:
                output = err if not output.strip() else f"{output.rstrip()}\n{err}"
        if max_bytes is not None:
            raw = output.encode("utf-8", errors="replace")
            if len(raw) > max_bytes:
                marker = b"\n...[truncated]..."
                output = (raw[: max_bytes - len(marker)] + marker).decode("utf-8", errors="replace")
        return output.strip()

    def _make_git_engine(self):
        engine = Mock()
        engine._run_git_command.side_effect = self._run_git_command
        return engine

    def _git(self, cwd, *args):
        return REAL_SUBPROCESS_RUN(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )

    def _create_git_repo_with_history(self, name):
        repo_path = Path(self.tmpdir.name) / name
        (repo_path / "src").mkdir(parents=True)
        self._git(repo_path.parent, "init", repo_path.name)
        self._git(repo_path, "config", "user.name", "Test User")
        self._git(repo_path, "config", "user.email", "test@example.com")
        target = repo_path / "src" / "app.py"
        target.write_text("print('one')\n", encoding="utf-8")
        self._git(repo_path, "add", "src/app.py")
        self._git(repo_path, "commit", "-m", "initial commit")
        first_hash = self._git(repo_path, "rev-parse", "HEAD").stdout.strip()
        target.write_text("print('two')\n", encoding="utf-8")
        self._git(repo_path, "add", "src/app.py")
        self._git(repo_path, "commit", "-m", "update app")
        second_hash = self._git(repo_path, "rev-parse", "HEAD").stdout.strip()
        return repo_path, first_hash, second_hash

    def test_get_objective_debug_endpoint_returns_filtered_entries(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        engine = Mock()
        engine.orchestrator.get_debug_entries.return_value = [{"event": "x", "level": "error"}]
        handler = self._make_handler(
            engine,
            "/api/objectives/" + objective["id"] + "/debug?limit=20&level=error",
        )

        handler.do_GET()

        engine.orchestrator.get_debug_entries.assert_called_once_with(objective["id"], limit=20, level="error")
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, [{"event": "x", "level": "error"}])

    def test_delete_objective_endpoint_stops_cleanup_and_deletes(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        engine = Mock()
        handler = self._make_handler(engine, "/api/objectives/" + objective["id"])

        handler.do_DELETE()

        engine.orchestrator.stop_and_cleanup.assert_called_once_with(objective["id"])
        self.assertFalse((self.objectives_dir / objective["id"]).exists())
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    def test_projects_crud_endpoints(self):
        root_path = Path(self.tmpdir.name) / "server-project"
        root_path.mkdir()
        create_payload = {
            "name": "Server Project",
            "rootPath": str(root_path),
            "defaultBaseBranch": "develop",
        }
        create_body = json.dumps(create_payload).encode("utf-8")
        create_handler = self._make_handler(Mock(), "/api/projects")
        create_handler.headers = {"Content-Length": str(len(create_body))}
        create_handler.rfile = io.BytesIO(create_body)

        create_handler.do_POST()

        created = json.loads(create_handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(created["name"], "Server Project")
        self.assertEqual(created["rootPath"], str(root_path))
        self.assertEqual(created["defaultBaseBranch"], "develop")

        list_handler = self._make_handler(Mock(), "/api/projects")
        list_handler.do_GET()
        listed = json.loads(list_handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual([item["id"] for item in listed], [created["id"]])

        patch_payload = {"name": "Renamed Project", "defaultBaseBranch": "main"}
        patch_body = json.dumps(patch_payload).encode("utf-8")
        patch_handler = self._make_handler(Mock(), f"/api/projects/{created['id']}")
        patch_handler.headers = {"Content-Length": str(len(patch_body))}
        patch_handler.rfile = io.BytesIO(patch_body)

        patch_handler.do_PATCH()

        patched = json.loads(patch_handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(patched["name"], "Renamed Project")
        self.assertEqual(patched["defaultBaseBranch"], "main")

        delete_handler = self._make_handler(Mock(), f"/api/projects/{created['id']}")
        delete_handler.do_DELETE()
        deleted = json.loads(delete_handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(deleted, {"ok": True})

    def test_create_project_endpoint_rejects_duplicate_root_path(self):
        root_path = Path(self.tmpdir.name) / "duplicate-server-project"
        root_path.mkdir()
        objectives.create_project("Existing", str(root_path), "main")
        payload = {"name": "Duplicate", "rootPath": str(root_path), "defaultBaseBranch": "develop"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(Mock(), "/api/projects")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        handler.send_response.assert_called_once_with(409)
        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["ok"], False)

    def test_pick_project_root_endpoint_returns_selected_folder(self):
        selected_path = Path(self.tmpdir.name) / "picked-project"
        selected_path.mkdir()

        with patch("cmux_harness.routes.projects.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=str(selected_path) + "\n",
                stderr="",
            )
            handler = self._post_json("/api/projects/pick-root", {})

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True, "path": str(selected_path)})
        mock_run.assert_called_once_with(
            ["osascript", "-e", 'POSIX path of (choose folder with prompt "Choose Project Folder")'],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_pick_project_root_endpoint_handles_cancel(self):
        with patch("cmux_harness.routes.projects.subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.CalledProcessError(
                returncode=1,
                cmd=["osascript"],
                stderr="execution error: User canceled. (-128)",
            )
            handler = self._post_json("/api/projects/pick-root", {})

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": False, "cancelled": True})

    def test_get_and_delete_project_endpoints_return_not_found_for_missing_project(self):
        get_handler = self._make_handler(Mock(), "/api/projects/missing-project")

        get_handler.do_GET()

        get_handler.send_response.assert_called_once_with(404)
        self.assertEqual(json.loads(get_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "project not found"})

        delete_handler = self._make_handler(Mock(), "/api/projects/missing-project")

        delete_handler.do_DELETE()

        delete_handler.send_response.assert_called_once_with(404)
        self.assertEqual(json.loads(delete_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "project not found"})

    def test_patch_project_endpoint_rejects_duplicate_root_path_and_non_git_root(self):
        first_root = Path(self.tmpdir.name) / "project-one"
        second_root = Path(self.tmpdir.name) / "project-two"
        nongit_root = Path(self.tmpdir.name) / "plain-folder"
        first_root.mkdir()
        second_root.mkdir()
        nongit_root.mkdir()
        first = objectives.create_project("One", str(first_root), "main")
        objectives.create_project("Two", str(second_root), "develop")

        duplicate_body = json.dumps({"rootPath": str(second_root)}).encode("utf-8")
        duplicate_handler = self._make_handler(Mock(), f"/api/projects/{first['id']}")
        duplicate_handler.headers = {"Content-Length": str(len(duplicate_body))}
        duplicate_handler.rfile = io.BytesIO(duplicate_body)

        duplicate_handler.do_PATCH()

        duplicate_handler.send_response.assert_called_once_with(409)
        self.assertEqual(json.loads(duplicate_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "project already exists for rootPath"})

        self.mock_run.side_effect = subprocess.CalledProcessError(returncode=128, cmd=["git"], stderr="not a git repository")
        nongit_body = json.dumps({"rootPath": str(nongit_root)}).encode("utf-8")
        nongit_handler = self._make_handler(Mock(), f"/api/projects/{first['id']}")
        nongit_handler.headers = {"Content-Length": str(len(nongit_body))}
        nongit_handler.rfile = io.BytesIO(nongit_body)

        nongit_handler.do_PATCH()

        nongit_handler.send_response.assert_called_once_with(400)
        self.assertEqual(json.loads(nongit_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "not a git repository"})

    def test_patch_project_name_preserves_other_fields(self):
        root_path = Path(self.tmpdir.name) / "rename-only-project"
        root_path.mkdir()
        project = objectives.create_project("Original", str(root_path), "develop")
        body = json.dumps({"name": "Renamed"}).encode("utf-8")
        handler = self._make_handler(Mock(), f"/api/projects/{project['id']}")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_PATCH()

        patched = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(patched["name"], "Renamed")
        self.assertEqual(patched["rootPath"], str(root_path))
        self.assertEqual(patched["defaultBaseBranch"], "develop")

    def test_delete_project_endpoint_allows_delete_after_last_objective_removed(self):
        root_path = Path(self.tmpdir.name) / "delete-after-objective"
        root_path.mkdir()
        project = objectives.create_project("Delete Later", str(root_path), "main")
        objective = objectives.create_objective("Ship feature", project_id=project["id"])
        objectives.delete_objective(objective["id"])
        handler = self._make_handler(Mock(), f"/api/projects/{project['id']}")

        handler.do_DELETE()

        self.assertEqual(json.loads(handler.wfile.getvalue().decode("utf-8")), {"ok": True})

    def test_delete_project_endpoint_rejects_when_objectives_exist(self):
        root_path = Path(self.tmpdir.name) / "guarded-server-project"
        root_path.mkdir()
        project = objectives.create_project("Guarded", str(root_path), "main")
        objectives.create_objective("Ship feature", project_id=project["id"])
        handler = self._make_handler(Mock(), f"/api/projects/{project['id']}")

        handler.do_DELETE()

        handler.send_response.assert_called_once_with(409)
        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response, {"ok": False, "error": "cannot delete project with existing objectives"})

    def test_create_objective_endpoint_passes_branch_name(self):
        engine = Mock()
        payload = {"goal": "Ship feature", "projectDir": "/tmp/project", "baseBranch": "develop", "branchName": "feature/api"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["branchName"], "feature/api")

    def test_create_objective_endpoint_uses_project_defaults_and_workflow_mode(self):
        root_path = Path(self.tmpdir.name) / "objective-project"
        root_path.mkdir()
        project = objectives.create_project("Objective Project", str(root_path), "develop")
        engine = Mock()
        payload = {"goal": "Ship feature", "projectId": project["id"], "workflowMode": "direct"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["projectId"], project["id"])
        self.assertEqual(response["baseBranch"], "develop")
        self.assertEqual(response["workflowMode"], "direct")

    def test_create_objective_endpoint_project_branch_override_wins(self):
        root_path = Path(self.tmpdir.name) / "objective-project-override"
        root_path.mkdir()
        project = objectives.create_project("Objective Project", str(root_path), "develop")
        engine = Mock()
        payload = {"goal": "Ship feature", "projectId": project["id"], "baseBranch": "release/2026"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["projectId"], project["id"])
        self.assertEqual(response["baseBranch"], "release/2026")

    def test_create_objective_endpoint_defaults_invalid_workflow_mode_to_structured(self):
        root_path = Path(self.tmpdir.name) / "objective-project-workflow"
        root_path.mkdir()
        project = objectives.create_project("Objective Project", str(root_path), "develop")
        engine = Mock()
        payload = {"goal": "Ship feature", "projectId": project["id"], "workflowMode": "wild-west"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["workflowMode"], "structured")

    def test_create_objective_endpoint_requires_project_selection(self):
        engine = Mock()
        engine.default_project_dir = "/tmp/legacy-default"
        payload = {"goal": "Ship feature", "baseBranch": "main"}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        handler.send_response.assert_called_once_with(400)
        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response, {"ok": False, "error": "goal and projectId or projectDir required"})

    def test_approve_plan_endpoint_calls_orchestrator(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        engine = Mock()
        engine.orchestrator.approve_plan.return_value = True
        handler = self._make_handler(engine, "/api/objectives/" + objective["id"] + "/approve-plan")
        handler.headers = {"Content-Length": "2"}
        handler.rfile = io.BytesIO(b"{}")

        handler.do_POST()

        engine.orchestrator.approve_plan.assert_called_once_with(objective["id"])
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    def test_approve_contracts_endpoint_calls_orchestrator(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        engine = Mock()
        engine.orchestrator.approve_contracts.return_value = True
        handler = self._make_handler(engine, "/api/objectives/" + objective["id"] + "/approve-contracts")
        handler.headers = {"Content-Length": "2"}
        handler.rfile = io.BytesIO(b"{}")

        handler.do_POST()

        engine.orchestrator.approve_contracts.assert_called_once_with(objective["id"])
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    def test_get_config_includes_contract_review_flag(self):
        engine = MagicMock()
        engine._lock.__enter__.return_value = None
        engine._lock.__exit__.return_value = None
        engine.poll_interval = 5
        engine.model = "test-model"
        engine.review_enabled = True
        engine.review_model = "review-model"
        engine.review_backend = "ollama"
        engine.contract_review_enabled = False
        engine.default_project_dir = "/tmp/project"
        engine.default_base_branch = "main"
        handler = self._make_handler(engine, "/api/config")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["contractReviewEnabled"], False)

    def test_post_config_updates_contract_review_flag(self):
        engine = MagicMock()
        engine._lock.__enter__.return_value = None
        engine._lock.__exit__.return_value = None
        engine.poll_interval = 5
        engine.model = "test-model"
        engine.review_enabled = True
        engine.review_model = "review-model"
        engine.review_backend = "ollama"
        engine.contract_review_enabled = False
        engine.default_project_dir = "/tmp/project"
        engine.default_base_branch = "main"

        def _set_contract_review(enabled=None):
            engine.contract_review_enabled = bool(enabled)

        engine.set_contract_review_config.side_effect = _set_contract_review
        handler = self._post_json(
            "/api/config",
            {"contractReviewEnabled": True},
            engine=engine,
        )

        engine.set_contract_review_config.assert_called_once_with(enabled=True)
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["contractReviewEnabled"], True)

    @patch("cmux_harness.server.cmux_api.cmux_send_to_workspace", return_value=True)
    def test_post_send_supports_text_input(self, mock_send):
        engine = MagicMock()
        engine._lock.__enter__.return_value = None
        engine._lock.__exit__.return_value = None
        engine._build_virtual_workspaces.return_value = [{
            "index": 7,
            "_real_index": 3,
            "uuid": "ws-123",
            "_surface_id": "surface:1",
            "name": "Workspace 7",
        }]
        engine.fingerprints = {}

        handler = self._post_json("/api/send", {"index": 7, "text": "hello\n"}, engine=engine)

        mock_send.assert_called_once_with(
            3,
            0,
            text="hello\n",
            key=None,
            workspace_uuid="ws-123",
            surface_id="surface:1",
        )
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    @patch("cmux_harness.server.cmux_api.cmux_send_to_workspace", return_value=True)
    def test_post_send_supports_navigation_keys(self, mock_send):
        engine = MagicMock()
        engine._lock.__enter__.return_value = None
        engine._lock.__exit__.return_value = None
        engine._build_virtual_workspaces.return_value = [{
            "index": 7,
            "_real_index": 3,
            "uuid": "ws-123",
            "_surface_id": "surface:1",
            "name": "Workspace 7",
        }]
        engine.fingerprints = {}

        handler = self._post_json("/api/send", {"index": 7, "key": "tab"}, engine=engine)

        mock_send.assert_called_once_with(
            3,
            0,
            text=None,
            key="tab",
            workspace_uuid="ws-123",
            surface_id="surface:1",
        )
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    def test_post_send_rejects_unsupported_keys(self):
        handler = self._post_json("/api/send", {"index": 7, "key": "left"}, engine=Mock())

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": False, "error": "unsupported key: left"})

    def test_post_workspace_star_maps_virtual_index_to_real_workspace(self):
        engine = MagicMock()
        engine._lock.__enter__.return_value = None
        engine._lock.__exit__.return_value = None
        engine._build_virtual_workspaces.return_value = [{
            "index": 7001,
            "_real_index": 7,
            "uuid": "ws-123",
            "name": "Workspace 7",
        }]
        engine.set_workspace_starred.return_value = True

        handler = self._post_json("/api/workspace-star", {"index": 7001, "starred": True}, engine=engine)

        engine.set_workspace_starred.assert_called_once_with(7, True)
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True, "starred": True})

    @patch("cmux_harness.server.cmux_api._v2_request")
    @patch("cmux_harness.server.subprocess.run")
    def test_post_new_session_supports_plain_terminal_mode(self, mock_run, mock_v2_request):
        project_path = Path(self.tmpdir.name) / "plain-terminal-project"
        project_path.mkdir()

        engine = MagicMock()
        engine.ws_config = {}
        engine.orchestrator._inject_hook_config = MagicMock()

        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        workspace_lists = iter([
            {"workspaces": [{"id": "existing-ws", "title": "Existing", "index": 1}]},
            {"workspaces": [
                {"id": "existing-ws", "title": "Existing", "index": 1},
                {"id": "ws-shell", "title": "plain-terminal-project shell", "index": 2},
            ]},
        ])

        def _v2_side_effect(method, params):
            if method == "workspace.list":
                return next(workspace_lists)
            return None

        mock_v2_request.side_effect = _v2_side_effect

        handler = self._post_json(
            "/api/new-session",
            {
                "projectPath": str(project_path),
                "branchName": "",
                "prompt": "",
                "command": "zsh",
                "sessionName": "plain-terminal-project shell",
            },
            engine=engine,
        )

        mock_run.assert_called_once_with(
            ["cmux", "new-workspace", "--name", "plain-terminal-project shell", "--cwd", str(project_path), "--command", "zsh"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        engine.orchestrator._inject_hook_config.assert_not_called()
        self.assertEqual(engine.ws_config["ws-shell"]["customName"], "plain-terminal-project shell")
        engine._save_config.assert_called_once()
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["branchName"], "")
        self.assertEqual(body["worktreePath"], str(project_path))
        self.assertEqual(body["workspace"], {"index": 2, "uuid": "ws-shell"})

    @patch("cmux_harness.server.cmux_api._v2_request")
    @patch("cmux_harness.server.subprocess.run")
    def test_post_new_session_injects_hook_config_for_claude_sessions(self, mock_run, mock_v2_request):
        project_path = Path(self.tmpdir.name) / "claude-session-project"
        project_path.mkdir()

        engine = MagicMock()
        engine.ws_config = {}
        engine.orchestrator._inject_hook_config = MagicMock()

        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        workspace_lists = iter([
            {"workspaces": [{"id": "existing-ws", "title": "Existing", "index": 1}]},
            {"workspaces": [
                {"id": "existing-ws", "title": "Existing", "index": 1},
                {"id": "ws-claude", "title": "feature-branch", "index": 2},
            ]},
        ])

        def _v2_side_effect(method, params):
            if method == "workspace.list":
                return next(workspace_lists)
            return None

        mock_v2_request.side_effect = _v2_side_effect

        handler = self._post_json(
            "/api/new-session",
            {
                "projectPath": str(project_path),
                "branchName": "feature-branch",
                "prompt": "",
                "command": "claude",
            },
            engine=engine,
        )

        engine.orchestrator._inject_hook_config.assert_called_once_with(str(project_path / ".claude" / "worktrees" / "feature-branch"))
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["workspace"], {"index": 2, "uuid": "ws-claude"})

    def test_message_endpoint_starts_background_thread_and_returns_ok(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        engine = Mock()
        payload = {"message": "Need a change here", "context": {"source": "chat"}}
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(engine, "/api/objectives/" + objective["id"] + "/message")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        with patch("cmux_harness.server.threading.Thread") as mock_thread:
            thread = mock_thread.return_value

            handler.do_POST()

        mock_thread.assert_called_once_with(
            target=engine.orchestrator.handle_human_input,
            args=(objective["id"], "Need a change here", {"source": "chat"}),
            daemon=True,
        )
        thread.start.assert_called_once_with()
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})

    def test_file_content_endpoint_returns_repo_file_contents(self):
        repo_path = Path(self.tmpdir.name) / "repo-file-content"
        repo_path.mkdir(parents=True)
        (repo_path / "docs").mkdir()
        (repo_path / "docs" / "guide.md").write_text("# Guide\n\nHello\n", encoding="utf-8")

        handler = self._post_json(
            "/api/file-content",
            {"path": str(repo_path), "file": "docs/guide.md"},
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True, "content": "# Guide\n\nHello\n"})

    def test_file_content_endpoint_rejects_path_traversal(self):
        repo_path = Path(self.tmpdir.name) / "repo-file-traversal"
        repo_path.mkdir(parents=True)
        handler = self._post_json(
            "/api/file-content",
            {"path": str(repo_path), "file": "../secret.txt"},
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(400)
        self.assertEqual(body, {"ok": False, "error": "invalid file path"})

    def test_file_content_endpoint_rejects_files_over_limit(self):
        repo_path = Path(self.tmpdir.name) / "repo-file-too-large"
        repo_path.mkdir(parents=True)
        (repo_path / "large.md").write_text("a" * (500 * 1024 + 1), encoding="utf-8")

        handler = self._post_json(
            "/api/file-content",
            {"path": str(repo_path), "file": "large.md"},
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(413)
        self.assertEqual(body, {"ok": False, "error": "file too large"})

    def test_file_content_endpoint_returns_404_for_missing_file(self):
        repo_path = Path(self.tmpdir.name) / "repo-file-missing"
        repo_path.mkdir(parents=True)

        handler = self._post_json(
            "/api/file-content",
            {"path": str(repo_path), "file": "missing.md"},
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(404)
        self.assertEqual(body, {"ok": False, "error": "file not found"})

    def test_git_commit_files_returns_changed_files(self):
        repo_path, _first_hash, second_hash = self._create_git_repo_with_history("repo-commit-files")

        handler = self._post_json(
            "/api/git-commit-files",
            {"path": str(repo_path), "hash": second_hash},
            engine=self._make_git_engine(),
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True, "files": [{"status": "M", "file": "src/app.py"}]})

    def test_git_commit_files_rejects_invalid_hash(self):
        repo_path = Path(self.tmpdir.name) / "repo-invalid-hash"
        repo_path.mkdir(parents=True)

        handler = self._post_json(
            "/api/git-commit-files",
            {"path": str(repo_path), "hash": "not-a-hash"},
            engine=self._make_git_engine(),
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(400)
        self.assertEqual(body, {"ok": False, "error": "invalid hash"})

    def test_git_commit_diff_returns_diff_for_commit(self):
        repo_path, _first_hash, second_hash = self._create_git_repo_with_history("repo-commit-diff")

        handler = self._post_json(
            "/api/git-commit-diff",
            {"path": str(repo_path), "hash": second_hash, "file": "src/app.py"},
            engine=self._make_git_engine(),
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertIn("diff --git a/src/app.py b/src/app.py", body["diff"])
        self.assertIn("-print('one')", body["diff"])
        self.assertIn("+print('two')", body["diff"])

    def test_open_worktree_route_opens_active_worktree_in_vscode(self):
        worktree_path = Path(self.tmpdir.name) / "objective-worktree"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)

        with patch("cmux_harness.routes.file_browser.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
            handler = self._post_json(
                f"/api/objectives/{objective['id']}/open-worktree",
                {},
            )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True, "rootPath": str(worktree_path.resolve()), "editor": "vscode"})
        mock_run.assert_called_once_with(
            ["open", "-a", "Visual Studio Code", str(worktree_path.resolve())],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_open_in_native_resolves_git_rename_to_existing_path(self):
        repo_path, _first_hash, _second_hash = self._create_git_repo_with_history("repo-open-native-rename")
        self._git(repo_path, "mv", "src/app.py", "src/renamed.py")

        with patch("cmux_harness.server.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
            handler = self._post_json(
                "/api/open-in-native",
                {"cwd": str(repo_path), "file": "src/app.py -> src/renamed.py"},
                engine=self._make_git_engine(),
            )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        expected_path = str((repo_path / "src" / "renamed.py").resolve())
        self.assertEqual(body, {"ok": True, "path": expected_path})
        mock_run.assert_called_once_with(["open", expected_path], check=True, capture_output=True, text=True)

    def test_get_build_log_returns_exists_false_when_file_is_missing(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-missing-build-log"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], False)
        self.assertEqual(body["lines"], [])
        self.assertEqual(body["totalLines"], 0)
        self.assertEqual(body["fileSize"], 0)
        self.assertEqual(body["fileSizeHuman"], "0 B")
        self.assertEqual(body["truncated"], False)

    def test_get_build_log_returns_tail_lines_when_file_exists(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-build-log-tail"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_build_log(objective, ["line 1", "line 2", "line 3"])
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], True)
        self.assertEqual(body["lines"], ["line 1", "line 2", "line 3"])
        self.assertEqual(body["totalLines"], 3)
        self.assertEqual(body["truncated"], False)
        self.assertGreater(body["fileSize"], 0)

    def test_get_build_log_respects_lines_param_default_and_maximum(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-build-log-limits"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        lines = [f"line {index}" for index in range(1105)]
        self._write_build_log(objective, lines)

        default_handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log")
        default_handler.do_GET()
        default_body = json.loads(default_handler.wfile.getvalue().decode("utf-8"))

        capped_handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log?lines=5000")
        capped_handler.do_GET()
        capped_body = json.loads(capped_handler.wfile.getvalue().decode("utf-8"))

        self.assertEqual(len(default_body["lines"]), 200)
        self.assertEqual(default_body["lines"][0], "line 905")
        self.assertEqual(default_body["lines"][-1], "line 1104")
        self.assertEqual(default_body["truncated"], True)
        self.assertEqual(len(capped_body["lines"]), 1000)
        self.assertEqual(capped_body["lines"][0], "line 105")
        self.assertEqual(capped_body["lines"][-1], "line 1104")
        self.assertEqual(capped_body["truncated"], True)

    def test_get_build_log_supports_prebuild_log_file_selection(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-prebuild-log"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_build_log(objective, ["prebuild only"], filename="prebuild.log")
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log?file=prebuild.log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], True)
        self.assertEqual(body["lines"], ["prebuild only"])

    def test_get_build_log_rejects_invalid_filenames(self):
        objective = self._create_objective_with_worktree(Path(self.tmpdir.name) / "worktree-invalid-build-file")
        invalid_files = ["../etc/passwd", "foo/bar.log"]

        for invalid_file in invalid_files:
            handler = self._make_handler(
                Mock(),
                f"/api/objectives/{objective['id']}/build-log?file={invalid_file}",
            )

            handler.do_GET()

            body = json.loads(handler.wfile.getvalue().decode("utf-8"))
            handler.send_response.assert_called_once_with(400)
            self.assertEqual(body, {"ok": False, "error": "invalid file"})

    def test_get_build_log_returns_404_for_nonexistent_objective(self):
        handler = self._make_handler(Mock(), "/api/objectives/missing/build-log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(404)
        self.assertEqual(body, {"ok": False, "error": "objective not found"})

    def test_get_build_log_returns_400_when_objective_has_no_worktree_path(self):
        objective = self._create_objective_with_worktree()
        objectives.update_objective(objective["id"], {"worktreePath": ""})
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/build-log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(400)
        self.assertEqual(body, {"ok": False, "error": "objective worktreePath required"})

    def test_get_console_logs_returns_exists_false_when_logs_directory_is_missing(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-logs-missing"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/console-logs")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], False)
        self.assertEqual(body["files"], [])
        self.assertEqual(body["activeFile"], "")
        self.assertEqual(body["lines"], [])
        self.assertEqual(body["matchedLines"], 0)

    def test_get_console_logs_returns_exists_false_when_no_log_files_exist(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-logs-empty"
        (worktree_path / ".build" / "logs").mkdir(parents=True)
        (worktree_path / ".build" / "logs" / "notes.txt").write_text("not a log\n", encoding="utf-8")
        objective = self._create_objective_with_worktree(worktree_path)
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/console-logs")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], False)
        self.assertEqual(body["files"], [])
        self.assertEqual(body["lines"], [])

    def test_get_console_logs_returns_unfiltered_tail_lines(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-tail"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_console_log(objective, "console.log", [f"line {index}" for index in range(6)])
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/console-logs?lines=3")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], True)
        self.assertEqual(body["files"], ["console.log"])
        self.assertEqual(body["activeFile"], "console.log")
        self.assertEqual(body["lines"], ["line 3", "line 4", "line 5"])
        self.assertEqual(body["totalLines"], 6)
        self.assertEqual(body["matchedLines"], 6)
        self.assertEqual(body["truncated"], True)

    def test_get_console_logs_applies_server_side_regex_filter(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-filter"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_console_log(objective, "console.log", ["INFO start", "error one", "INFO done", "ERROR two"])
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/console-logs?filter=error",
        )

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["lines"], ["error one", "ERROR two"])
        self.assertEqual(body["matchedLines"], 2)
        self.assertEqual(body["totalLines"], 4)
        self.assertEqual(body["filter"], "error")

    def test_get_console_logs_returns_400_on_invalid_regex(self):
        objective = self._create_objective_with_worktree(Path(self.tmpdir.name) / "worktree-console-invalid-regex")
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/console-logs?filter=[invalid",
        )

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(400)
        self.assertIn("invalid regex:", body["error"])
        self.assertEqual(body["ok"], False)

    def test_get_console_logs_includes_multiple_log_files_in_response(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-multiple"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_console_log(objective, "a.log", ["a1"])
        self._write_console_log(objective, "b.log", ["b1"])
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/console-logs")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["files"], ["a.log", "b.log"])
        self.assertEqual(body["activeFile"], "a.log")
        self.assertEqual(body["lines"], ["a1"])

    def test_get_console_logs_file_param_selects_specific_log_file(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-file-select"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_console_log(objective, "a.log", ["a1"])
        self._write_console_log(objective, "b.log", ["b1", "b2"])
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/console-logs?file=b.log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["activeFile"], "b.log")
        self.assertEqual(body["lines"], ["b1", "b2"])

    def test_get_console_logs_rejects_invalid_filenames(self):
        objective = self._create_objective_with_worktree(Path(self.tmpdir.name) / "worktree-console-invalid-file")
        invalid_files = ["../etc/passwd", "foo/bar.log"]

        for invalid_file in invalid_files:
            handler = self._make_handler(
                Mock(),
                f"/api/objectives/{objective['id']}/console-logs?file={invalid_file}",
            )

            handler.do_GET()

            body = json.loads(handler.wfile.getvalue().decode("utf-8"))
            handler.send_response.assert_called_once_with(400)
            self.assertEqual(body, {"ok": False, "error": "invalid file"})

    def test_get_console_logs_matched_lines_count_is_correct_with_filter(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-match-count"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        self._write_console_log(objective, "console.log", ["match 1", "skip", "match 2", "match 3"])
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/console-logs?filter=match&lines=2",
        )

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["matchedLines"], 3)
        self.assertEqual(body["lines"], ["match 2", "match 3"])
        self.assertEqual(body["truncated"], True)

    def test_get_console_logs_filter_applies_before_deque(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-console-filter-before-deque"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)
        lines = ["match 1", "noise 1", "noise 2", "noise 3", "match 2", "noise 4", "match 3"]
        self._write_console_log(objective, "console.log", lines)
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/console-logs?filter=match&lines=2",
        )

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["lines"], ["match 2", "match 3"])
        self.assertEqual(body["matchedLines"], 3)

    def test_get_console_logs_returns_404_for_nonexistent_objective(self):
        handler = self._make_handler(Mock(), "/api/objectives/missing/console-logs")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(404)
        self.assertEqual(body, {"ok": False, "error": "objective not found"})

    def test_get_workspace_build_log_returns_tail_lines_when_file_exists(self):
        root_path = Path(self.tmpdir.name) / "workspace-build-log-tail"
        workspace = self._create_workspace(root_path=root_path, name="Feature Workspace")
        log_path = root_path / ".build" / "build.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("line 1\nline 2\nline 3\n", encoding="utf-8")
        handler = self._make_handler(Mock(), f"/api/workspaces/{workspace['id']}/build-log")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], True)
        self.assertEqual(body["lines"], ["line 1", "line 2", "line 3"])
        self.assertEqual(body["totalLines"], 3)
        self.assertEqual(body["truncated"], False)

    def test_get_workspace_console_logs_returns_tail_lines(self):
        root_path = Path(self.tmpdir.name) / "workspace-console-tail"
        workspace = self._create_workspace(root_path=root_path, name="Console Workspace")
        log_path = root_path / ".build" / "logs" / "console.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("line 0\nline 1\nline 2\nline 3\n", encoding="utf-8")
        handler = self._make_handler(Mock(), f"/api/workspaces/{workspace['id']}/console-logs?lines=2")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["exists"], True)
        self.assertEqual(body["files"], ["console.log"])
        self.assertEqual(body["activeFile"], "console.log")
        self.assertEqual(body["lines"], ["line 2", "line 3"])
        self.assertEqual(body["matchedLines"], 4)

    def test_get_workspace_status_summary_returns_workspace_payload(self):
        root_path = Path(self.tmpdir.name) / "workspace-status-summary"
        workspace = self._create_workspace(root_path=root_path, name="Status Workspace")
        workspaces.append_workspace_message(workspace["id"], {
            "timestamp": "2026-04-07T12:00:00+00:00",
            "type": "assistant",
            "content": "Indexed the repo and ready for the next step.",
        })
        engine = Mock()
        engine.orchestrator.get_workspace_messages.return_value = workspaces.load_workspace_messages(workspace["id"])
        handler = self._make_handler(engine, f"/api/workspaces/{workspace['id']}/status-summary")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["workspaceId"], workspace["id"])
        self.assertEqual(body["objective"], "Status Workspace")
        self.assertEqual(body["stage"]["label"], "Idle")
        self.assertIn("signals", body)
        self.assertIn("git", body["signals"])
        self.assertEqual(body["summarySource"]["kind"], "deterministic")

    def test_get_workspace_active_turn_returns_pending_turn_payload(self):
        root_path = Path(self.tmpdir.name) / "workspace-active-turn"
        workspace = self._create_workspace(root_path=root_path, name="Active Turn Workspace")
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="What are you doing?")
        workspaces.update_workspace_turn(
            workspace["id"],
            turn["id"],
            {
                "progressSummary": "Checking repo status and recent changes.",
                "progressState": "working",
                "progressUpdatedAt": "2026-04-07T12:00:05+00:00",
                "progressSequence": 1,
            },
        )
        handler = self._make_handler(Mock(), f"/api/workspaces/{workspace['id']}/active-turn")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["id"], turn["id"])
        self.assertEqual(body["progressSummary"], "Checking repo status and recent changes.")
        self.assertEqual(body["status"], "pending")

    def test_get_objective_screen_prefers_planner_workspace_snapshot(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "status": "planning",
                "plannerWorkspaceId": "ws-planner",
                "orchestratorSessionId": "ws-orch",
                "orchestratorSessionActive": True,
            },
        )
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/screen?lines=120")

        with patch("cmux_harness.routes.objectives.cmux_api.cmux_read_workspace", return_value="planner output\n") as mock_read:
            handler.do_GET()

        mock_read.assert_called_once_with(0, 0, lines=120, workspace_uuid="ws-planner")
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["screen"], "planner output\n")
        self.assertEqual(body["lines"], 120)

    def test_get_objective_screen_returns_conflict_when_no_active_session(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/screen")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(409)
        self.assertEqual(body, {"ok": False, "error": "Objective session is not active"})

    def test_get_objective_screen_can_return_archived_planner_snapshot(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "status": "negotiating_contracts",
                "plannerArchivedWorkspaceId": "ws-planner-archived",
            },
        )
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/screen?lines=120&source=archived_planner",
        )

        with patch("cmux_harness.routes.objectives.cmux_api.cmux_read_workspace", return_value="archived planner output\n") as mock_read:
            handler.do_GET()

        mock_read.assert_called_once_with(0, 0, lines=120, workspace_uuid="ws-planner-archived")
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["screen"], "archived planner output\n")
        self.assertEqual(body["lines"], 120)

    def test_get_objective_screen_archived_planner_conflicts_when_missing(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        handler = self._make_handler(
            Mock(),
            f"/api/objectives/{objective['id']}/screen?source=archived_planner",
        )

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        handler.send_response.assert_called_once_with(409)
        self.assertEqual(body, {"ok": False, "error": "Archived planner session is not available"})

    def test_get_workspace_screen_returns_active_session_snapshot(self):
        root_path = Path(self.tmpdir.name) / "workspace-screen"
        workspace = self._create_workspace(root_path=root_path, name="Screen Workspace")
        workspaces.update_workspace_session(
            workspace["id"],
            {
                "cmuxWorkspaceId": "ws-123",
                "sessionActive": True,
                "status": "active",
            },
        )
        handler = self._make_handler(Mock(), f"/api/workspaces/{workspace['id']}/screen?lines=120")

        with patch("cmux_harness.routes.workspaces.cmux_api.cmux_read_workspace", return_value="live terminal output\n") as mock_read:
            handler.do_GET()

        mock_read.assert_called_once_with(0, 0, lines=120, workspace_uuid="ws-123")
        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["screen"], "live terminal output\n")
        self.assertEqual(body["lines"], 120)

    def test_post_workspace_turn_finalize_appends_assistant_message(self):
        root_path = Path(self.tmpdir.name) / "workspace-turn-finalize"
        workspace = self._create_workspace(root_path=root_path, name="Callback Workspace")
        engine = Mock()
        engine.callback_base_url = "http://127.0.0.1:9091"
        engine.orchestrator = Orchestrator(engine)
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="Need TL;DR")
        payload = {
            "token": turn["token"],
            "content": "TL;DR delivered through callback.",
            "source": "callback-helper",
        }
        handler = self._post_json(
            f"/api/workspaces/{workspace['id']}/turns/{turn['id']}/finalize",
            payload,
            engine=engine,
        )

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body["ok"], True)
        self.assertEqual(body["status"], "completed")
        messages = engine.orchestrator.get_workspace_messages(workspace["id"])
        self.assertEqual(messages[-1]["type"], "assistant")
        self.assertEqual(messages[-1]["content"], "TL;DR delivered through callback.")

    def test_post_workspace_turn_finalize_rejects_invalid_token(self):
        root_path = Path(self.tmpdir.name) / "workspace-turn-invalid-token"
        workspace = self._create_workspace(root_path=root_path, name="Callback Workspace")
        engine = Mock()
        engine.callback_base_url = "http://127.0.0.1:9091"
        engine.orchestrator = Orchestrator(engine)
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="Need TL;DR")
        handler = self._post_json(
            f"/api/workspaces/{workspace['id']}/turns/{turn['id']}/finalize",
            {
                "token": "wrong-token",
                "content": "Nope",
            },
            engine=engine,
        )

        self.assertEqual(handler.send_response.call_args.args, (403,))
        self.assertEqual(
            json.loads(handler.wfile.getvalue().decode("utf-8")),
            {"ok": False, "error": "invalid turn token"},
        )

    def test_delete_workspace_endpoint_closes_session_and_deletes_workspace(self):
        root_path = Path(self.tmpdir.name) / "workspace-delete"
        workspace = self._create_workspace(root_path=root_path, name="Delete Workspace")
        engine = Mock()
        handler = self._make_handler(engine, f"/api/workspaces/{workspace['id']}")

        handler.do_DELETE()

        engine.orchestrator.close_workspace_session.assert_called_once_with(workspace["id"], reason="delete")
        self.assertFalse((self.workspaces_dir / workspace["id"]).exists())
        self.assertEqual(json.loads(handler.wfile.getvalue().decode("utf-8")), {"ok": True})

    def test_post_workspace_start_sets_starting_status_and_returns_immediately(self):
        root_path = Path(self.tmpdir.name) / "workspace-start"
        workspace = self._create_workspace(root_path=root_path, name="Start Workspace")
        engine = Mock()
        handler = self._make_handler(engine, f"/api/workspaces/{workspace['id']}/start")
        handler.rfile = io.BytesIO(b'{}')
        handler.headers = {"Content-Length": "2", "Content-Type": "application/json"}

        with patch("cmux_harness.routes.workspaces.threading") as mock_threading:
            handler.do_POST()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})
        updated = workspaces.read_workspace_session(workspace["id"])
        self.assertEqual(updated["status"], "starting")
        mock_threading.Thread.assert_called_once()
        mock_threading.Thread.return_value.start.assert_called_once()

    def test_post_workspace_start_background_thread_sets_error_on_failure(self):
        root_path = Path(self.tmpdir.name) / "workspace-start-fail"
        workspace = self._create_workspace(root_path=root_path, name="Fail Workspace")
        engine = Mock()
        engine.orchestrator.start_workspace_session.return_value = None

        handler = self._make_handler(engine, f"/api/workspaces/{workspace['id']}/start")
        handler.rfile = io.BytesIO(b'{}')
        handler.headers = {"Content-Length": "2", "Content-Type": "application/json"}

        captured_target = []
        def capture_thread(*args, **kwargs):
            captured_target.append(kwargs.get("target"))
            return Mock()
        with patch("cmux_harness.routes.workspaces.threading") as mock_threading:
            mock_threading.Thread.side_effect = capture_thread
            handler.do_POST()

        self.assertEqual(len(captured_target), 1)
        captured_target[0]()
        updated = workspaces.read_workspace_session(workspace["id"])
        self.assertEqual(updated["status"], "error")

    def test_get_action_buttons_returns_default_button(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/action-buttons")

        handler.do_GET()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(
            body,
            {
                "buttons": [
                    {
                        "id": "default-build-run",
                        "label": "Build & Run",
                        "icon": "▶",
                        "color": "#34d399",
                        "prompt": "/exp-project-run",
                        "isDefault": True,
                        "order": 0,
                    }
                ]
            },
        )

    def test_post_action_buttons_creates_new_button(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        payload = {
            "label": "Ship It",
            "prompt": "/ship-it",
            "icon": "S",
            "color": "#112233",
        }
        body = json.dumps(payload).encode("utf-8")
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/action-buttons")
        handler.headers = {"Content-Length": str(len(body))}
        handler.rfile = io.BytesIO(body)

        handler.do_POST()

        response = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(response["ok"], True)
        self.assertEqual(response["button"]["label"], "Ship It")
        self.assertEqual(response["button"]["prompt"], "/ship-it")
        self.assertEqual(response["button"]["icon"], "S")
        self.assertEqual(response["button"]["color"], "#112233")
        self.assertEqual(response["button"]["order"], 0)
        self.assertTrue(response["button"]["id"])
        stored = objectives.read_objective(objective["id"])
        self.assertEqual(stored["actionButtons"], [response["button"]])

    def test_delete_action_button_removes_button(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.set_action_buttons(
            objective["id"],
            [
                {
                    "id": "button-1",
                    "label": "Ship It",
                    "icon": "S",
                    "color": "#112233",
                    "prompt": "/ship-it",
                    "order": 0,
                }
            ],
        )
        handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/action-buttons/button-1")

        handler.do_DELETE()

        body = json.loads(handler.wfile.getvalue().decode("utf-8"))
        self.assertEqual(body, {"ok": True})
        stored = objectives.read_objective(objective["id"])
        self.assertEqual(stored["actionButtons"], [])

    def test_removed_objective_file_browser_routes_return_not_found(self):
        worktree_path = Path(self.tmpdir.name) / "worktree-files-removed-routes"
        worktree_path.mkdir(parents=True)
        objective = self._create_objective_with_worktree(worktree_path)

        list_handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/files")
        list_handler.do_GET()
        self.assertEqual(list_handler.send_response.call_args_list[0].args, (404,))
        self.assertEqual(json.loads(list_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "objective not found"})

        preview_handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/files/content?path=notes.txt")
        preview_handler.do_GET()
        self.assertEqual(preview_handler.send_response.call_args_list[0].args, (404,))
        self.assertEqual(json.loads(preview_handler.wfile.getvalue().decode("utf-8")), {"ok": False, "error": "objective not found"})

        open_handler = self._make_handler(Mock(), f"/api/objectives/{objective['id']}/files/open")
        open_handler.send_error = Mock()
        body = json.dumps({"path": "notes.txt"}).encode("utf-8")
        open_handler.headers = {"Content-Length": str(len(body))}
        open_handler.rfile = io.BytesIO(body)
        open_handler.do_POST()
        open_handler.send_error.assert_called_once_with(404)

    def test_debug_modal_static_markup_includes_rendering_regression_fix(self):
        html = Path("cmux_harness/static/orchestrator.html").read_text(encoding="utf-8")
        css = Path("cmux_harness/static/orchestrator.css").read_text(encoding="utf-8")
        js = Path("cmux_harness/static/orchestrator.js").read_text(encoding="utf-8")

        self.assertIn('<link rel="stylesheet" href="/orchestrator.css">', html)
        self.assertIn('<script src="/orchestrator.js"></script>', html)
        self.assertIn(".debug-entry {\n    border: 1px solid var(--b);\n    border-radius: 8px;", css)
        self.assertNotIn(".debug-entry {\n    border: 1px solid var(--b);\n    border-radius: 12px;\n    background: var(--raised);\n    overflow: hidden;", css)
        self.assertIn(".debug-entry-head {\n    display: flex;\n    align-items: center;\n    gap: 10px;\n    min-height: 36px;", css)
        self.assertIn("'<div class=\"debug-entry-time\">' + esc(relativeTime(entry.timestamp)) + '</div>'", js)
        self.assertIn("'<div class=\"debug-event\">' + esc(entry.event || 'unknown') + '</div>'", js)
