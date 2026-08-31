import http.server
import json
import logging
import threading
import time
import unittest

from herdr_harness.agent_activity import AgentActivityManager
from herdr_harness.service import HerdrService


def envelope(pane_id, event):
    return {"pane_id": pane_id, "event": event}


def tool(name, args=None):
    return envelope("w1:p1", {"type": "tool_execution_start", "toolName": name, "args": args or {}})


def settled(pane_id="w1:p1"):
    return envelope(pane_id, {"type": "agent_settled"})


def wait_until(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class FakeRepo:
    def __init__(self, session_status=None):
        self.calls = []
        self.revision = 0
        self.session_status = dict(session_status or {})
        self.return_none = False

    def update_session_activity(
        self,
        pane_id,
        *,
        activity_message,
        activity_message_at=None,
        status=None,
        last_seen_at=None,
        actor="agent:activity",
    ):
        self.calls.append(
            {
                "pane_id": pane_id,
                "activity_message": activity_message,
                "activity_message_at": activity_message_at,
                "status": status,
                "last_seen_at": last_seen_at,
                "actor": actor,
            }
        )
        if self.return_none:
            return None
        self.revision += 1
        effective = status or self.session_status.get(pane_id, "unknown")
        self.session_status[pane_id] = effective
        return {
            "id": "item_x",
            "revision": self.revision,
            "pi_sessions": [{"pane_id": pane_id, "status": effective}],
        }


class FakeBroker:
    def __init__(self):
        self.events = []

    def publish(self, event, data):
        self.events.append((event, data))


class ActivityModelHandler(http.server.BaseHTTPRequestHandler):
    server_state = None

    def do_POST(self):
        state = ActivityModelHandler.server_state
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        state["requests"].append((self.path, body))
        delay, status, payload = (
            state["responses"].pop(0)
            if state["responses"]
            else (0, 200, {"choices": [{"message": {"content": "working"}}]})
        )
        if delay:
            time.sleep(delay)
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


class FakeHerdrClient:
    socket_path = "/private/tmp/fake-herdr.sock"
    session = "fixtures"


class AgentActivityManagerTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ActivityModelHandler)
        ActivityModelHandler.server_state = {"requests": [], "responses": []}
        self.model_url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2.0)

    def make_manager(self, repo, broker, *, model_url=None, name="test-model", timeout=0.2, debounce=None, extra=None):
        environ = {"HERDR_HARNESS_ACTIVITY_MODEL_NAME": name}
        if model_url is not None:
            environ["HERDR_HARNESS_ACTIVITY_MODEL_URL"] = model_url
        if extra:
            environ.update(extra)
        manager = AgentActivityManager(repo, broker, environ=environ, timeout=timeout, debounce=debounce)
        manager.start()
        self.addCleanup(manager.stop)
        return manager

    def test_canned_rules_hit_order(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "pushing")

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertEqual(repo.calls[1]["activity_message"], "committing")

        manager.handle_event(tool("bash", {"command": "gh pr list"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 3))
        self.assertEqual(repo.calls[2]["activity_message"], "reviewing")

        manager.handle_event(tool("bash", {"command": "pytest -q tests"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 4))
        self.assertEqual(repo.calls[3]["activity_message"], "running tests")

        manager.handle_event(tool("subagent", {"agent": "architect"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 5))
        self.assertEqual(repo.calls[4]["activity_message"], "delegating")

        manager.handle_event(envelope("w1:reads", {"type": "tool_execution_start", "toolName": "read", "args": {"path": "a.py"}}))
        manager.handle_event(envelope("w1:reads", {"type": "tool_execution_start", "toolName": "grep", "args": {"pattern": "x"}}))
        manager.handle_event(envelope("w1:reads", {"type": "tool_execution_start", "toolName": "find", "args": {"path": "."}}))
        manager.handle_event(settled("w1:reads"))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 6))
        self.assertEqual(repo.calls[5]["activity_message"], "scanning code")

        manager.handle_event(envelope("w1:writes", {"type": "tool_execution_start", "toolName": "write", "args": {"path": "a.py"}}))
        manager.handle_event(envelope("w1:writes", {"type": "tool_execution_start", "toolName": "edit", "args": {"path": "a.py"}}))
        manager.handle_event(envelope("w1:writes", {"type": "tool_execution_start", "toolName": "read", "args": {"path": "a.py"}}))
        manager.handle_event(settled("w1:writes"))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 7))
        self.assertEqual(repo.calls[6]["activity_message"], "editing code")

        manager.handle_event(envelope("w1:web", {"type": "tool_execution_start", "toolName": "web_search", "args": {"query": "x"}}))
        manager.handle_event(settled("w1:web"))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 8))
        self.assertEqual(repo.calls[7]["activity_message"], "browsing")

    def test_newest_first_and_intra_entry_rule_priority(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        # Rule priority is a pure function of the ring: newest-first, then
        # intra-entry ordering (git push before pytest, subagent on top).
        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        self.assertEqual(manager._canned_phrase("w1:p1"), "pushing")

        manager.handle_event(tool("bash", {"command": "git commit -m second"}))
        self.assertEqual(manager._canned_phrase("w1:p1"), "committing")

        manager.handle_event(tool("bash", {"command": "git push && pytest"}))
        self.assertEqual(manager._canned_phrase("w1:p1"), "pushing")

        manager.handle_event(tool("subagent", {"agent": "architect"}))
        self.assertEqual(manager._canned_phrase("w1:p1"), "delegating")

        # The settled write lands the newest-first phrase end to end.
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: repo.calls and repo.calls[-1]["activity_message"] == "delegating"))

    def test_tool_events_debounced_and_settled_bypasses(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="", debounce=300)

        # A settled write arms the per-pane debounce window.
        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "committing")

        # tool_execution_start alone (phrase changed) is held inside the window;
        # tool_call only feeds the ring and never schedules a write.
        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(tool("read", {"path": "a.py"}))
        manager.handle_event(envelope("w1:p1", {"type": "tool_call", "toolCall": {"name": "write", "arguments": {"path": "b.py"}}}))
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)

        # agent_settled bypasses the debounce even inside the window.
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertEqual(repo.calls[1]["activity_message"], "pushing")

        # A fresh pane: tool_execution_start alone (no prior write) writes once,
        # then settles.
        manager.handle_event(envelope("w1:other", {"type": "tool_execution_start", "toolName": "bash", "args": {"command": "git push"}}))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 3))
        self.assertEqual(repo.calls[2]["activity_message"], "pushing")

    def test_phrase_change_gating(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))

        manager.handle_event(settled())
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)
        self.assertEqual(len([e for e in broker.events if e[0] == "active_work.updated"]), 1)

        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertEqual(repo.calls[1]["activity_message"], "pushing")
        self.assertEqual(len([e for e in broker.events if e[0] == "active_work.updated"]), 2)

    def test_phrase_gating_resets_across_session_boundary(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))

        manager.handle_event(envelope("w1:p1", {"type": "session_shutdown"}))
        manager.handle_event(tool("bash", {"command": "git commit -m again"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertEqual(repo.calls[1]["activity_message"], "committing")

    def test_model_success_writes_sanitized_output(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url=self.model_url)
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "  scanning   code  "}}]})
        )
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "a b c d"}}]})
        )

        manager.handle_event(tool("experimental_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "scanning code")

        # The tool trigger and the settled trigger each make one model call;
        # the settled call consumes the garbage response and is skipped.
        self.assertEqual(len(ActivityModelHandler.server_state["requests"]), 2)
        path, body = ActivityModelHandler.server_state["requests"][0]
        self.assertEqual(path, "/v1/chat/completions")
        payload = json.loads(body)
        self.assertEqual(payload["model"], "test-model")
        self.assertEqual(payload["max_tokens"], 24)
        self.assertEqual(payload["temperature"], 0)
        self.assertEqual(payload["chat_template_kwargs"], {"enable_thinking": False})
        content = payload["messages"][0]["content"]
        self.assertLess(len(content), 2048)
        self.assertIn("experimental_tool", content)
        self.assertNotIn("option", content)
        self.assertNotIn("{", content)

    def test_sse_envelope_matches_active_work_shape(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(broker.events) > 0))
        event, data = broker.events[0]
        self.assertEqual(event, "active_work.updated")
        self.assertEqual(data["work_item_id"], "item_x")
        self.assertEqual(data["revision"], 1)
        self.assertEqual(data["change"], "activity")
        self.assertIn("generated_at", data)
        self.assertTrue(data["generated_at"].endswith("Z"))

    def test_model_garbage_rejected_and_falls_back_to_working(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url=self.model_url)

        cases = [
            (0, 200, {"choices": [{"message": {"content": "a b c d"}}]}),
            (0, 200, {"choices": [{"message": {"content": "x" * 45}}]}),
            (0, 200, {"choices": [{"message": {"content": "\n  \n"}}]}),
            (0, 200, {"choices": "not-a-list"}),
            (0, 200, {"unexpected": True}),
            (0, 500, {"error": "boom"}),
            (0, 200, "not even json"),
            (0, 200, {"choices": [{"message": {"content": "line one\nline two"}}]}),
        ]
        ActivityModelHandler.server_state["responses"].extend(cases)

        manager.handle_event(tool("experimental_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "working")

        # The second tool trigger is held by the debounce (no model call);
        # only the two settled triggers call the model again.
        manager.handle_event(tool("experimental_tool", {"option": "y"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(ActivityModelHandler.server_state["requests"]) == 3))
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)

    def test_model_failure_keeps_previous_phrase(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url=self.model_url)
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "experimenting"}}]})
        )
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "a b c d"}}]})
        )

        manager.handle_event(tool("experimental_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "experimenting")

        ActivityModelHandler.server_state["responses"].append((0, 500, {"error": "boom"}))
        manager.handle_event(tool("experimental_tool", {"option": "y"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(ActivityModelHandler.server_state["requests"]) == 3))
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)
        self.assertEqual(repo.calls[0]["activity_message"], "experimenting")

    def test_model_timeout_falls_back_to_working(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url=self.model_url, timeout=0.2)
        ActivityModelHandler.server_state["responses"].append((0.8, 200, {"choices": [{"message": {"content": "slow"}}]}))

        manager.handle_event(tool("experimental_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1, timeout=3.0))
        self.assertEqual(repo.calls[0]["activity_message"], "working")

    def test_model_timeout_after_previous_phrase_keeps_it(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url=self.model_url, timeout=0.2)
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "experimenting"}}]})
        )
        ActivityModelHandler.server_state["responses"].append(
            (0, 200, {"choices": [{"message": {"content": "a b c d"}}]})
        )

        manager.handle_event(tool("experimental_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))

        # The second tool trigger is held by the debounce; only the second
        # settled trigger times out on the model again.
        ActivityModelHandler.server_state["responses"].append((0.8, 200, {"choices": [{"message": {"content": "slow"}}]}))
        manager.handle_event(tool("experimental_tool", {"option": "y"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(ActivityModelHandler.server_state["requests"]) == 3))
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)

    def test_malformed_envelopes_never_raise(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        malformed = [
            None,
            [],
            "text",
            42,
            {},
            {"pane_id": 7, "event": {"type": "agent_settled"}},
            {"pane_id": "w1:p1"},
            {"pane_id": "w1:p1", "event": None},
            {"pane_id": "w1:p1", "event": "agent_settled"},
            {"pane_id": "w1:p1", "event": {"type": "tool_execution_start"}},
            {"pane_id": "w1:p1", "event": {"type": "tool_execution_start", "toolName": ""}},
            {"pane_id": "w1:p1", "event": {"type": "tool_call", "toolCall": "not-a-dict"}},
            {"pane_id": "w1:p1", "event": {"type": 99}},
        ]
        for item in malformed:
            manager.handle_event(item)

        time.sleep(0.2)
        self.assertEqual(repo.calls, [])
        self.assertEqual(broker.events, [])

        manager.handle_event(tool("bash", {"command": "git push"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "pushing")

    def test_canned_only_mode_when_url_empty(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "pushing")
        self.assertEqual(ActivityModelHandler.server_state["requests"], [])
        self.assertEqual(manager.model_url, "")

    def test_no_match_canned_only_writes_working(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("mystery_tool", {"option": "x"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "working")
        self.assertEqual(ActivityModelHandler.server_state["requests"], [])

        manager.handle_event(settled())
        time.sleep(0.2)
        self.assertEqual(len(repo.calls), 1)

    def test_status_promoted_from_unknown(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["status"], "running")

        manager.handle_event(tool("bash", {"command": "git push"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertIsNone(repo.calls[1]["status"])

    def test_status_not_overridden_when_blocked(self):
        repo = FakeRepo(session_status={"w1:p1": "blocked"})
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["status"], "running")

        repo.session_status["w1:p1"] = "blocked"
        manager.handle_event(tool("bash", {"command": "git push"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertIsNone(repo.calls[1]["status"])

    def test_no_matching_session_skips_cleanly(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")
        repo.return_none = True

        with self.assertLogs("herdr_harness.agent_activity", level="WARNING") as captured:
            manager.handle_event(tool("bash", {"command": "git push"}))
            manager.handle_event(settled())
            # Both the tool and settled triggers attempt a write; the missing
            # session swallows them and nothing is published. The pane-miss
            # log is rate-limited to one line per pane.
            self.assertTrue(wait_until(lambda: len(repo.calls) >= 2))
            time.sleep(0.2)
            self.assertEqual(broker.events, [])
            self.assertEqual(len(captured.records), 1)
            self.assertEqual(captured.records[0].levelno, logging.WARNING)
            self.assertIn("w1:p1", captured.records[0].getMessage())

        repo.calls.clear()
        repo.return_none = False
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "pushing")
        self.assertEqual(len(broker.events), 1)

    def test_debounce_holds_changed_phrase_inside_window(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="", debounce=0.15)

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "committing")

        # Changed phrase, but the write happened inside the debounce window.
        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        time.sleep(0.05)
        self.assertEqual(len(repo.calls), 1)

        # Once the window elapses, a fresh tool trigger lands the write.
        time.sleep(0.2)
        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2, timeout=2.0))
        self.assertEqual(repo.calls[1]["activity_message"], "pushing")

    def test_agent_settled_bypasses_debounce(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="", debounce=300)

        manager.handle_event(tool("bash", {"command": "git commit -m fix"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "committing")

        # Inside the (large) window a settled write still lands immediately.
        manager.handle_event(tool("bash", {"command": "git push origin main"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 2))
        self.assertEqual(repo.calls[1]["activity_message"], "pushing")

    def test_debounce_env_override_and_clamp(self):
        repo = FakeRepo()
        broker = FakeBroker()
        cases = [
            ({"HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS": "7"}, 7.0),
            ({"HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS": "1"}, 2.0),
            ({"HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS": "500"}, 300.0),
            ({"HERDR_HARNESS_ACTIVITY_DEBOUNCE_SECONDS": "junk"}, 20.0),
            ({}, 20.0),
        ]
        for environ, expected in cases:
            with self.subTest(environ=environ):
                manager = AgentActivityManager(repo, broker, environ=environ, timeout=0.2)
                self.assertEqual(manager.debounce_seconds, expected)

    def test_ring_is_bounded(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        for index in range(70):
            manager.handle_event(tool("read", {"path": "x.py"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "scanning code")
        self.assertLessEqual(len(manager._rings["w1:p1"]), 48)

    def test_tool_call_event_envelope_shape(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = self.make_manager(repo, broker, model_url="")

        manager.handle_event(envelope("w1:p1", {"type": "tool_call", "toolCall": {"name": "write", "arguments": {"path": "b.py"}}}))
        manager.handle_event(envelope("w1:p1", {"type": "tool_call", "toolCall": {"name": "edit", "arguments": {"path": "a.py"}}}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "editing code")

    def test_start_stop_idempotent(self):
        repo = FakeRepo()
        broker = FakeBroker()
        manager = AgentActivityManager(repo, broker, environ={}, timeout=0.2)
        manager.start()
        manager.start()
        manager.stop()
        manager.stop()
        self.assertTrue(manager._thread is None or not manager._thread.is_alive())
        manager.start()
        manager.handle_event(tool("bash", {"command": "git push"}))
        manager.handle_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        manager.stop()


class AgentActivityWiringTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ActivityModelHandler)
        ActivityModelHandler.server_state = {"requests": [], "responses": []}
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2.0)

    def test_dispatcher_routes_to_publish_and_activity_manager(self):
        repo = FakeRepo()
        broker = FakeBroker()
        service = HerdrService(
            FakeHerdrClient(),
            environ={"HERDR_HARNESS_ACTIVITY_MODEL_URL": ""},
            active_work=repo,
            broker=broker,
        )
        self.assertIs(service.pi_semantic._on_event.__func__, service._dispatch_pi_event.__func__)
        self.assertIs(service.agent_activity.active_work, repo)
        self.assertIs(service.agent_activity.broker, broker)

        service.agent_activity.start()
        self.addCleanup(service.agent_activity.stop)

        event = {"type": "agent_settled"}
        service._dispatch_pi_event(envelope("w1:p1", event))
        self.assertTrue(wait_until(lambda: any(e[0] == "pi.agent_settled" for e in broker.events)))
        for item in broker.events:
            if item[0] == "pi.agent_settled":
                self.assertEqual(item[1], envelope("w1:p1", event))

        repo.calls.clear()
        service._dispatch_pi_event(tool("bash", {"command": "git push origin main"}))
        service._dispatch_pi_event(settled())
        self.assertTrue(wait_until(lambda: len(repo.calls) == 1))
        self.assertEqual(repo.calls[0]["activity_message"], "pushing")
        self.assertTrue(any(e[0] == "active_work.updated" for e in broker.events))

        service.stop()

    def test_non_settled_events_still_publish_without_activity(self):
        repo = FakeRepo()
        broker = FakeBroker()
        service = HerdrService(
            FakeHerdrClient(),
            environ={"HERDR_HARNESS_ACTIVITY_MODEL_URL": ""},
            active_work=repo,
            broker=broker,
        )
        service.agent_activity.start()
        self.addCleanup(service.agent_activity.stop)

        service._dispatch_pi_event(envelope("w1:p1", {"type": "bridge.connection", "connected": True}))
        self.assertTrue(wait_until(lambda: any(e[0] == "pi.bridge.connection" for e in broker.events)))
        time.sleep(0.2)
        self.assertEqual(repo.calls, [])

        service.stop()


if __name__ == "__main__":
    unittest.main()
