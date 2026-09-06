import base64
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from herdr_harness.quick_voice import QuickVoiceError, QuickVoiceManager, parse_plan, settled_result


class Planner:
    def generate_text(self, prompt, *, system, max_tokens):
        if 'tasks' in system:
            return json.dumps({"title": "Two investigations", "tasks": [
                {"title": "Find build cause", "prompt": "Investigate the build failure, read only."},
                {"title": "Check release notes", "prompt": "Read release notes and report changes, read only."}]})
        evidence = json.loads(prompt)
        return "I checked both items. The build needs attention." if any(t["status"] != "done" for t in evidence["results"]) else "I checked both items. The build passed and the release notes are current."


class FakeService:
    def __init__(self):
        self.environ = {}
        self.launches = []
        self.prompts = {}
        self.model = {"provider": "custom-lux-dspark", "id": "qwen3.8-27b-nvfp4-dspark"}
        self.thinking_level = "high"
        self.snapshot_reads = []
        self.finished = False
        self.audio_gate = threading.Event()
        self.audio_gate.set()
        self.fail_audio = False
        self.fail_dispatch = False
        self.response_audio = SimpleNamespace(synthesize=self.synthesize)

    def synthesize(self, *, text):
        self.audio_gate.wait(3)
        if self.fail_audio:
            raise OSError("Kokoro unavailable")
        return {"audioBase64": base64.b64encode(b"I" * 700).decode()}

    def quick_pi_session(self, title, **kwargs):
        self.launches.append((title, kwargs))
        return {"pane_id": f"w1:p{len(self.launches)}"}

    def _quick_wait_for_pi_session(self, *_):
        pass

    def pi_command(self, pane_id, command, payload):
        self.prompts[pane_id] = payload["text"]
        if self.fail_dispatch:
            raise TimeoutError("reply lost")

    def pi_snapshot_response(self, pane_id):
        self.snapshot_reads.append(pane_id)
        entries = [
            {"message": {"role": "user", "content": self.prompts[pane_id]}},
            {"message": {"role": "assistant", "content": [{"type": "text", "text": "Verified result"}], "stopReason": "stop"}}
        ] if pane_id in self.prompts else []
        return {"connected": True, "state": {"idle": self.finished, "isStreaming": not self.finished,
                "model": self.model, "thinkingLevel": self.thinking_level}, "entries": entries}


class QuickVoiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.service = FakeService()
        self.manager = QuickVoiceManager(self.service, store_path=Path(self.temp.name), planner=Planner(), poll_seconds=.005)
        self.addCleanup(self.manager.stop)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = self.manager.get("note-1")["job"]
            if predicate(result):
                return result
            time.sleep(.005)
        self.fail("Quick voice did not reach the expected state")

    def test_agents_start_while_ack_audio_is_blocked_and_one_combined_report_follows(self):
        self.service.audio_gate.clear()
        self.addCleanup(self.service.audio_gate.set)
        self.manager.start(request_id="note-1", text="Check the build and release notes")
        job = self.wait_for(lambda j: j["status"] == "running")
        self.assertEqual(len(self.service.prompts), 2)
        self.assertEqual(job["messages"][0]["audioStatus"], "preparing")
        self.assertTrue(all(not args["focus"] for _, args in self.service.launches))
        self.assertTrue(all(args["workspace_label"] == "Quick Voice" for _, args in self.service.launches))
        self.service.audio_gate.set()
        self.service.finished = True
        job = self.wait_for(lambda j: j["status"] == "done" and j["messages"][-1]["audioStatus"] == "ready")
        self.assertEqual([m["id"] for m in job["messages"]], ["ack", "report"])
        self.assertGreater(len(self.manager.audio("note-1", "report")["audioBase64"]), 512)

    def test_request_id_is_idempotent_and_rejects_different_content(self):
        first = self.manager.start(request_id="note-1", text="Check both")
        self.manager.start(request_id="note-1", text="Check both")
        self.wait_for(lambda j: j["status"] == "running")
        self.assertEqual(len(self.service.launches), 2)
        with self.assertRaises(QuickVoiceError) as caught:
            self.manager.start(request_id="note-1", text="Different request")
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(first["job"]["id"], "note-1")

    def test_each_agent_launches_with_qwen_high_and_records_confirmed_settings(self):
        original_prompt = self.service.pi_command
        def prompt_after_confirmation(pane_id, command, payload):
            self.assertIn(pane_id, self.service.snapshot_reads)
            return original_prompt(pane_id, command, payload)
        self.service.pi_command = prompt_after_confirmation
        self.manager.start(request_id="note-1", text="Check both")
        job = self.wait_for(lambda j: j["status"] == "running")
        expected_model = {"provider": "custom-lux-dspark", "id": "qwen3.8-27b-nvfp4-dspark"}
        self.assertEqual(len(self.service.prompts), 2)
        for _, options in self.service.launches:
            self.assertEqual(options["model"], expected_model)
            self.assertEqual(options["thinking_level"], "high")
        for task in job["tasks"]:
            self.assertEqual(task["model"], expected_model)
            self.assertEqual(task["thinkingLevel"], "high")

    def test_fallback_model_never_receives_the_request(self):
        self.service.model = {"provider": "fireworks", "id": "another-model"}
        self.manager.start(request_id="note-1", text="Check both")
        job = self.wait_for(lambda j: j["status"] == "needs_attention")
        self.assertFalse(self.service.prompts)
        self.assertTrue(all(t["status"] == "failed" for t in job["tasks"]))
        self.assertTrue(all("request was not sent" in t["result"] for t in job["tasks"]))

    def test_clamped_thinking_level_never_receives_the_request(self):
        self.service.thinking_level = "off"
        self.manager.start(request_id="note-1", text="Check both")
        job = self.wait_for(lambda j: j["status"] == "needs_attention")
        self.assertFalse(self.service.prompts)
        self.assertTrue(all("high thinking" in t["result"] for t in job["tasks"]))

    def test_audio_failure_does_not_fail_work(self):
        self.service.fail_audio = True
        self.service.finished = True
        self.manager.start(request_id="note-1", text="Check both")
        job = self.wait_for(lambda j: j["status"] == "done" and j["messages"][-1]["audioStatus"] == "failed")
        self.assertIn("build passed", job["messages"][-1]["text"])

    def test_ambiguous_dispatch_is_never_retried_or_reported_successful(self):
        self.service.fail_dispatch = True
        self.manager.start(request_id="note-1", text="Check both")
        job = self.wait_for(lambda j: j["status"] == "needs_attention")
        self.assertEqual(len(self.service.launches), 2)
        self.assertTrue(all(t["paneID"] and t["status"] == "needs_attention" for t in job["tasks"]))
        self.assertIn("needs attention", job["messages"][-1]["text"])

    def test_restart_resumes_monitoring_without_sending_prompts_again(self):
        self.manager.start(request_id="note-1", text="Check both")
        self.wait_for(lambda j: j["status"] == "running" and j["messages"][0]["audioStatus"] == "ready")
        self.manager.stop()
        self.service.finished = True
        self.manager = QuickVoiceManager(self.service, store_path=Path(self.temp.name), planner=Planner(), poll_seconds=.005)
        self.addCleanup(self.manager.stop)
        self.manager.recover()
        self.wait_for(lambda j: j["status"] == "done")
        self.assertEqual(len(self.service.launches), 2)
        self.assertEqual(len(self.service.prompts), 2)

    def test_bad_plan_creates_no_sessions(self):
        self.manager.planner = SimpleNamespace(generate_text=lambda *a, **k: '{}')
        self.manager.start(request_id="note-1", text="Check both")
        self.wait_for(lambda j: j["status"] == "failed" and len(j["messages"]) == 2)
        self.assertEqual(self.service.launches, [])

    def test_plan_rejects_oversplitting_and_duplicate_assignments(self):
        for tasks in ([], [{"title": "x", "prompt": "same"}] * 2, [{"title": str(i), "prompt": str(i)} for i in range(5)]):
            with self.assertRaises(QuickVoiceError):
                parse_plan(json.dumps({"title": "Plan", "tasks": tasks}))

    def test_idle_old_answer_does_not_complete_a_new_prompt(self):
        snapshot = {"connected": True, "state": {"idle": True}, "entries": [{"message": {"role": "assistant", "content": "Old answer"}}]}
        self.assertIsNone(settled_result(snapshot, "new prompt"))
        snapshot["entries"].insert(0, {"message": {"role": "user", "content": "new prompt"}})
        self.assertEqual(settled_result(snapshot, "new prompt"), ("done", "Old answer"))
        snapshot["state"]["pendingMessages"] = True
        self.assertIsNone(settled_result(snapshot, "new prompt"))
        snapshot["state"] = {"idle": True}
        snapshot["entries"][-1]["message"]["stopReason"] = "toolUse"
        self.assertIsNone(settled_result(snapshot, "new prompt"))
        snapshot["entries"][-1]["message"]["stopReason"] = "error"
        self.assertEqual(settled_result(snapshot, "new prompt")[0], "failed")
        snapshot["pending_interactions"] = [{"id": "approval"}]
        self.assertEqual(settled_result(snapshot, "new prompt")[0], "needs_attention")
