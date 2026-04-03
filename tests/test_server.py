import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from cmux_harness import objectives
from cmux_harness.server import make_handler


class _BrokenPipeStream:
    def write(self, _body):
        raise BrokenPipeError


class TestServerResponses(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.patch_subprocess_run = patch("cmux_harness.objectives.subprocess.run")
        self.mock_run = self.patch_subprocess_run.start()
        self.mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        self.addCleanup(self.patch_subprocess_run.stop)

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

    def test_debug_modal_static_markup_includes_rendering_regression_fix(self):
        html = Path("cmux_harness/static/orchestrator.html").read_text(encoding="utf-8")

        self.assertIn(".debug-entry {\n    border: 1px solid var(--b);\n    border-radius: 8px;", html)
        self.assertNotIn(".debug-entry {\n    border: 1px solid var(--b);\n    border-radius: 12px;\n    background: var(--raised);\n    overflow: hidden;", html)
        self.assertIn(".debug-entry-head {\n    display: flex;\n    align-items: center;\n    gap: 10px;\n    min-height: 36px;", html)
        self.assertIn("'<div class=\"debug-entry-time\">' + esc(relativeTime(entry.timestamp)) + '</div>'", html)
        self.assertIn("'<div class=\"debug-event\">' + esc(entry.event || 'unknown') + '</div>'", html)
