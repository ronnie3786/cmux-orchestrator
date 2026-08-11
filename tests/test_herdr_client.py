import json
import os
import socket
import tempfile
import threading
import unittest

from herdr_harness.client import HerdrAPIError, HerdrClient, resolve_socket_path


class FakeHerdrSocket:
    def __init__(self, root):
        self.path = os.path.join(root, "herdr.sock")
        self.requests = []
        self.subscription_count = 0
        self.stop_event = threading.Event()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.path)
        self._server.listen()
        self._server.settimeout(0.1)
        self._thread = threading.Thread(target=self._accept, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def close(self):
        self.stop_event.set()
        self._server.close()
        self._thread.join(timeout=1)

    def _accept(self):
        while not self.stop_event.is_set():
            try:
                connection, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._handle, args=(connection,), daemon=True).start()

    def _handle(self, connection):
        with connection:
            reader = connection.makefile("rb")
            raw = reader.readline()
            if not raw:
                return
            request = json.loads(raw)
            self.requests.append(request)
            identifier = request["id"]
            method = request["method"]
            if method == "fail.test":
                response = {"id": identifier, "error": {"code": "test_failure", "message": "Nope"}}
                connection.sendall(json.dumps(response).encode() + b"\n")
                return
            if method == "events.subscribe":
                self.subscription_count += 1
                connection.sendall(
                    json.dumps({"id": identifier, "result": {"type": "subscription_started"}}).encode()
                    + b"\n"
                )
                event = {
                    "event": "workspace_updated",
                    "data": {
                        "type": "workspace_updated",
                        "workspace": {"workspace_id": f"w{self.subscription_count}"},
                    },
                }
                connection.sendall(json.dumps(event).encode() + b"\n")
                if self.subscription_count == 1:
                    return
                self.stop_event.wait(1)
                return
            if method == "session.snapshot":
                result = {
                    "type": "session_snapshot",
                    "snapshot": {
                        "version": "0.8.0",
                        "protocol": 19,
                        "workspaces": [],
                        "tabs": [],
                        "panes": [],
                        "layouts": [],
                        "agents": [],
                    },
                }
            else:
                result = {"type": "pong", "version": "0.8.0", "protocol": 19}
            connection.sendall(json.dumps({"id": identifier, "result": result}).encode() + b"\n")


class HerdrClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.fake = FakeHerdrSocket(self.temp.name).start()
        self.addCleanup(self.fake.close)

    def test_one_shot_request_uses_native_ndjson_envelope(self):
        client = HerdrClient(self.fake.path, timeout=1)

        result = client.request("ping", {}, request_id="test-ping")

        self.assertEqual(result["type"], "pong")
        self.assertEqual(
            self.fake.requests[0],
            {"id": "test-ping", "method": "ping", "params": {}},
        )

    def test_snapshot_unwraps_native_session_snapshot(self):
        snapshot = HerdrClient(self.fake.path, timeout=1).snapshot()

        self.assertEqual(snapshot["protocol"], 19)
        self.assertEqual(snapshot["workspaces"], [])

    def test_native_error_becomes_typed_exception(self):
        with self.assertRaises(HerdrAPIError) as context:
            HerdrClient(self.fake.path, timeout=1).request("fail.test", {})

        self.assertEqual(context.exception.code, "test_failure")
        self.assertEqual(str(context.exception), "Nope")

    def test_named_session_socket_resolution(self):
        path = resolve_socket_path(
            environ={
                "HERDR_SESSION": "ios-fixtures",
                "HERDR_CONFIG_PATH": "/private/tmp/herdr-config/config.toml",
            }
        )

        self.assertEqual(path, "/private/tmp/herdr-config/sessions/ios-fixtures/herdr.sock")

    def test_explicit_socket_wins_over_named_session(self):
        path = resolve_socket_path(
            "/private/tmp/custom-herdr.sock",
            "other",
            environ={"HERDR_SOCKET_PATH": "/private/tmp/ignored.sock"},
        )

        self.assertEqual(path, "/private/tmp/custom-herdr.sock")

    def test_empty_environment_does_not_leak_process_session(self):
        original = os.environ.get("HERDR_SESSION")
        os.environ["HERDR_SESSION"] = "ambient-session"
        try:
            client = HerdrClient(self.fake.path, environ={})
        finally:
            if original is None:
                os.environ.pop("HERDR_SESSION", None)
            else:
                os.environ["HERDR_SESSION"] = original

        self.assertEqual(client.session, "default")

    def test_subscription_reconnects_and_preserves_event_envelopes(self):
        client = HerdrClient(self.fake.path, timeout=0.25)
        stop = threading.Event()
        values = []

        def receive(event):
            values.append(event)
            if len(values) == 2:
                stop.set()

        thread = threading.Thread(
            target=client.subscribe_forever,
            args=(receive,),
            kwargs={
                "subscriptions": [{"type": "workspace.updated"}],
                "stop_event": stop,
                "minimum_backoff": 0.01,
                "maximum_backoff": 0.02,
            },
        )
        thread.start()
        thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual([item["data"]["workspace"]["workspace_id"] for item in values], ["w1", "w2"])
        subscribe_requests = [item for item in self.fake.requests if item["method"] == "events.subscribe"]
        self.assertGreaterEqual(len(subscribe_requests), 2)
        self.assertEqual(
            subscribe_requests[0]["params"]["subscriptions"],
            [{"type": "workspace.updated"}],
        )


if __name__ == "__main__":
    unittest.main()
