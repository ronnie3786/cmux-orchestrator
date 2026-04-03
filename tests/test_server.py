import io
import unittest
from unittest.mock import Mock

from cmux_harness.server import make_handler


class _BrokenPipeStream:
    def write(self, _body):
        raise BrokenPipeError


class TestServerResponses(unittest.TestCase):

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
