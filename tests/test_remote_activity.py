import io
import json
import time
import unittest

from herdr_harness.remote_activity import RemoteActivityPoller


def wait_until(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


def envelope(pane_id, cursor, event_type, **event_fields):
    return {
        "protocol": {"name": "herdr.pi.semantic", "version": 1},
        "pane_id": pane_id,
        "cursor": cursor,
        "event": {"type": event_type, **event_fields},
        "generated_at": "2026-08-31T12:00:00Z",
    }


def sse_data(payload) -> bytes:
    return f"data: {json.dumps(payload)}\n\n".encode("utf-8")


class FakeRemoteHarness:
    """Records requests; serves snapshot JSON and pre-scripted SSE streams."""

    def __init__(self, *, latest_cursor=4, streams=None):
        self.latest_cursor = latest_cursor
        self.streams = list(streams or [])
        self.snapshot_requests = []
        self.stream_requests = []
        self.received = []

    def on_event(self, payload):
        self.received.append(payload)

    def open_url(self, request, timeout=None):
        if "/pi/snapshot" in request.full_url:
            self.snapshot_requests.append(request)
            return io.BytesIO(
                json.dumps(
                    {
                        "ok": True,
                        "pane_id": "wZ:p2",
                        "cursor": self.latest_cursor,
                        "latest_cursor": self.latest_cursor,
                        "oldest_cursor": 1,
                    }
                ).encode("utf-8")
            )
        self.stream_requests.append(request)
        lines = self.streams.pop(0) if self.streams else []
        return io.BytesIO(b"".join(lines))


class RemoteActivityPollerTests(unittest.TestCase):
    def make_poller(self, active_panes, harness, *, prefix="devbox", poll="0.2"):
        environ = {
            "HERDR_HARNESS_REMOTE_ACTIVITY_URL": "https://devbox.example.test:8461",
            "HERDR_HARNESS_REMOTE_ACTIVITY_POLL_SECONDS": poll,
        }
        if prefix is not None:
            environ["HERDR_HARNESS_REMOTE_ACTIVITY_PREFIX"] = prefix
        poller = RemoteActivityPoller(
            lambda: set(active_panes),
            harness.on_event,
            environ=environ,
            open_url=harness.open_url,
        )
        self.addCleanup(poller.stop)
        return poller

    def test_disabled_without_remote_url(self):
        harness = FakeRemoteHarness()
        poller = RemoteActivityPoller(
            lambda: set(), harness.on_event, environ={}, open_url=harness.open_url
        )
        self.assertFalse(poller.enabled)
        poller.start()
        self.assertEqual(poller.pane_ids(), [])
        poller.stop()

    def test_start_attaches_readers_via_the_reconcile_loop(self):
        ready = sse_data(envelope("wZ:p2", 4, "ready", connected=True))
        tool = sse_data(
            envelope("wZ:p2", 5, "tool_execution_start", toolName="read", args={})
        )
        harness = FakeRemoteHarness(latest_cursor=4, streams=[[ready, tool]])
        poller = self.make_poller({"devbox:wZ:p2"}, harness, poll="0.2")

        poller.start()
        self.assertTrue(wait_until(lambda: len(harness.received) >= 1))
        self.assertEqual(poller.pane_ids(), ["wZ:p2"])
        poller.stop()
        self.assertTrue(wait_until(lambda: poller.pane_ids() == []))

    def test_watches_only_prefixed_board_panes_and_namespaces_events(self):
        ready = sse_data(envelope("wZ:p2", 4, "ready", connected=True))
        tool = sse_data(
            envelope("wZ:p2", 5, "tool_execution_start", toolName="read", args={})
        )
        harness = FakeRemoteHarness(latest_cursor=4, streams=[[ready, tool]])
        poller = self.make_poller({"devbox:wZ:p2", "w1:p1"}, harness)

        poller._reconcile()
        self.assertTrue(wait_until(lambda: len(harness.received) >= 1))

        self.assertEqual(poller.pane_ids(), ["wZ:p2"])
        self.assertGreaterEqual(len(harness.snapshot_requests), 1)
        self.assertGreaterEqual(len(harness.stream_requests), 1)
        self.assertEqual(harness.stream_requests[0].headers.get("Last-event-id"), "4")
        self.assertEqual(len(harness.received), 1)
        self.assertEqual(harness.received[0]["pane_id"], "devbox:wZ:p2")
        self.assertEqual(harness.received[0]["event"]["type"], "tool_execution_start")

    def test_reconnect_resumes_from_last_forwarded_cursor(self):
        harness = FakeRemoteHarness(
            latest_cursor=4,
            streams=[
                [
                    sse_data(envelope("wZ:p2", 4, "ready", connected=True)),
                    sse_data(
                        envelope("wZ:p2", 5, "tool_execution_start", toolName="read", args={})
                    ),
                ],
                [sse_data(envelope("wZ:p2", 6, "ready", connected=True))],
            ],
        )
        poller = self.make_poller({"devbox:wZ:p2"}, harness)

        poller._reconcile()
        self.assertTrue(wait_until(lambda: len(harness.received) >= 1))
        self.assertTrue(wait_until(lambda: len(harness.stream_requests) >= 2, timeout=5.0))
        self.assertEqual(harness.stream_requests[1].headers.get("Last-event-id"), "5")

    def test_ignores_panes_without_the_configured_prefix(self):
        harness = FakeRemoteHarness()
        poller = self.make_poller({"w1:p1"}, harness)
        poller._reconcile()
        self.assertEqual(poller.pane_ids(), [])
        self.assertEqual(harness.snapshot_requests, [])
        self.assertEqual(harness.stream_requests, [])
        self.assertEqual(harness.received, [])

    def test_unavailable_remote_pane_retries_without_crashing(self):
        harness = FakeRemoteHarness()

        def refusing(request, timeout=None):
            raise OSError("connection refused")

        harness.open_url = refusing
        poller = self.make_poller({"devbox:wZ:p2"}, harness)
        poller._reconcile()
        self.assertTrue(wait_until(lambda: poller.pane_ids() == ["wZ:p2"]))
        time.sleep(0.05)
        self.assertEqual(harness.received, [])


if __name__ == "__main__":
    unittest.main()
