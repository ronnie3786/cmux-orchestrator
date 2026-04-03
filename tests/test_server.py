import io
import json
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
