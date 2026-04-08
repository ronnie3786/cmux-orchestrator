import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import report_turn


class TestReportTurn(unittest.TestCase):

    def test_main_posts_turn_finalize_payload_from_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            content_path = Path(tmpdir) / "reply.md"
            content_path.write_text("Final callback answer.\n", encoding="utf-8")
            captured = {}

            class _Response:
                def __enter__(self):
                    return self

                def __exit__(self, exc_type, exc, tb):
                    return False

                def read(self):
                    return b'{"ok": true}'

            def _fake_urlopen(request, timeout=0):
                captured["url"] = request.full_url
                captured["payload"] = json.loads(request.data.decode("utf-8"))
                captured["timeout"] = timeout
                return _Response()

            with patch("cmux_harness.report_turn.urllib.request.urlopen", side_effect=_fake_urlopen):
                code = report_turn.main(
                    [
                        "--server-url", "http://127.0.0.1:9090",
                        "--workspace-id", "ws-123",
                        "--turn-id", "turn-456",
                        "--token", "secret-token",
                        "--file", str(content_path),
                    ]
                )

        self.assertEqual(code, 0)
        self.assertEqual(captured["url"], "http://127.0.0.1:9090/api/workspaces/ws-123/turns/turn-456/finalize")
        self.assertEqual(captured["payload"]["token"], "secret-token")
        self.assertEqual(captured["payload"]["content"], "Final callback answer.\n")
        self.assertEqual(captured["payload"]["source"], "callback-helper")

    def test_main_returns_error_for_missing_content_source(self):
        code = report_turn.main(
            [
                "--server-url", "http://127.0.0.1:9090",
                "--workspace-id", "ws-123",
                "--turn-id", "turn-456",
                "--token", "secret-token",
            ]
        )

        self.assertEqual(code, 2)
