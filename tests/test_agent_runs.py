import base64
import json
import os
import stat
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

from herdr_harness.agent_runs import (
    PUBLIC_RUN_KEYS,
    AgentRunError,
    AgentRunManager,
)
from herdr_harness.service import HerdrService
from tests.test_herdr_service import FakeQuickSessionClient, FakeReadyPiSemantic


def write_fake_pi(directory: Path) -> Path:
    path = directory / "fake-pi.py"
    path.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import os
            import sys
            import time
            from pathlib import Path

            def value(flag):
                return sys.argv[sys.argv.index(flag) + 1]

            if "--list-models" in sys.argv:
                marker_path = os.environ.get("FAKE_LIST_MODELS_CAPTURE")
                if marker_path:
                    with Path(marker_path).open("a", encoding="utf-8") as marker:
                        marker.write(json.dumps({"called": True}) + "\\n")
                table = os.environ.get("FAKE_LIST_MODELS_OUTPUT")
                if table is None:
                    table = "pi models\\nprovider               model                                  context  max-out  thinking  images\\ncustom-lux-dspark      qwen3.8-27b-nvfp4-dspark               98.3K    16.4K    yes       no\\nopenai-codex           gpt-5.6-luna                           272K     128K     yes       yes\\nother                  million                                 1M       32K      no        no\\nother                  literal                                 16384    8K       no        yes\\n"
                print(table, end="")
                raise SystemExit(0)

            prompt = sys.stdin.read()
            capture_path = os.environ.get("FAKE_AGENT_CAPTURE")
            if capture_path:
                Path(capture_path).write_text(json.dumps({
                    "argv": sys.argv[1:],
                    "prompt": prompt,
                    "cwd": os.getcwd(),
                    "herdrPaneId": os.environ.get("HERDR_PANE_ID"),
                    "herdrAgentRunId": os.environ.get("HERDR_AGENT_RUN_ID"),
                    "herdrAgentRunMode": os.environ.get("HERDR_AGENT_RUN_MODE"),
                }), encoding="utf-8")
            mode = os.environ.get("FAKE_AGENT_MODE", "success")
            if mode == "hang":
                time.sleep(60)
            if mode == "failure":
                print("fake Pi failed safely", file=sys.stderr, flush=True)
                raise SystemExit(7)
            session_id = value("--session-id")
            sessions_dir = Path(value("--session-dir"))
            if mode != "missing-session":
                session_file = sessions_dir / ("fixture_" + session_id + ".jsonl")
                session_file.write_text(
                    json.dumps({"type": "session", "id": session_id, "cwd": os.getcwd()}) + "\\n",
                    encoding="utf-8",
                )
            if mode == "tool-success":
                print(json.dumps({
                    "type": "tool_execution_start",
                    "toolCallId": "call-1",
                    "toolName": "read",
                    "args": {"path": "README.md"},
                }), flush=True)
                print(json.dumps({
                    "type": "tool_execution_update",
                    "toolCallId": "call-1",
                    "toolName": "read",
                    "args": {"path": "README.md"},
                    "partialResult": "ignore me",
                }), flush=True)
                print(json.dumps({
                    "type": "tool_execution_end",
                    "toolCallId": "call-1",
                    "toolName": "read",
                    "result": "file contents",
                    "isError": False,
                }), flush=True)
            elif mode == "tool-error":
                print(json.dumps({
                    "type": "tool_execution_start",
                    "toolCallId": "call-error",
                    "toolName": "bash",
                    "args": {"command": "false"},
                }), flush=True)
                print(json.dumps({
                    "type": "tool_execution_end",
                    "toolCallId": "call-error",
                    "toolName": "bash",
                    "result": "exit status 1",
                    "isError": True,
                }), flush=True)
            elif mode == "tool-end-only":
                print(json.dumps({
                    "type": "tool_execution_end",
                    "toolCallId": "orphan",
                    "toolName": "grep",
                    "result": {"matches": 3},
                    "isError": False,
                }), flush=True)
            elif mode == "tool-updates-only":
                for index in range(100):
                    print(json.dumps({
                        "type": "tool_execution_update",
                        "toolCallId": "update-" + str(index),
                        "toolName": "read",
                        "args": {"path": "ignored"},
                        "partialResult": "chunk",
                    }), flush=True)
            elif mode == "tool-cap":
                for index in range(201):
                    print(json.dumps({
                        "type": "tool_execution_start",
                        "toolCallId": "cap-" + str(index),
                        "toolName": "read",
                        "args": {"path": str(index)},
                    }), flush=True)
            elif mode == "tool-long-arg":
                print(json.dumps({
                    "type": "tool_execution_start",
                    "toolCallId": "long-arg",
                    "toolName": "read",
                    "args": "x" * 5000,
                }), flush=True)
            elif mode == "tool-malformed-arg":
                print(
                    '{"type":"tool_execution_start","toolCallId":"malformed",'
                    '"toolName":"read","args":NaN}',
                    flush=True,
                )
                print(json.dumps({
                    "type": "tool_execution_end",
                    "toolCallId": "malformed",
                    "toolName": "read",
                    "result": "ok",
                    "isError": False,
                }), flush=True)
            elif mode == "tool-burst":
                for index in range(50):
                    tool_call_id = "burst-" + str(index)
                    print(json.dumps({
                        "type": "tool_execution_start",
                        "toolCallId": tool_call_id,
                        "toolName": "read",
                        "args": {"path": str(index)},
                    }), flush=True)
                    print(json.dumps({
                        "type": "tool_execution_end",
                        "toolCallId": tool_call_id,
                        "toolName": "read",
                        "result": "ok",
                        "isError": False,
                    }), flush=True)
            if mode == "assistant-error":
                message = {
                    "role": "assistant",
                    "content": [],
                    "stopReason": "error",
                    "errorMessage": "401 status code (no body)",
                }
                print(json.dumps({"event": {"type": "message_end", "message": message}}), flush=True)
                print(json.dumps({"type": "agent_end", "messages": [message]}), flush=True)
            elif mode == "empty-text":
                print(json.dumps({"event": {
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "text": "   ",
                        "usage": {"cost": {"total": 0.0}},
                    },
                }}), flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            elif mode == "text-then-error":
                print(json.dumps({"event": {
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "text": "Partial answer",
                        "usage": {"cost": {"total": 0.01}},
                    },
                }}), flush=True)
                print(json.dumps({"event": {
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "content": [],
                        "stopReason": "error",
                        "errorMessage": "mid-stream failure",
                    },
                }}), flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            else:
                print(json.dumps({"event": {
                    "type": "message_end",
                    "message": {
                        "role": "assistant",
                        "text": "Fleet answer",
                        "usage": {"cost": {"total": 0.0123}},
                    },
                }}), flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            """
        ),
        encoding="utf-8",
    )
    os.chmod(path, 0o755)
    return path


def wait_for_status(manager: AgentRunManager, run_id: str, statuses, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        envelope = manager.get(run_id)
        if envelope["run"]["status"] in statuses:
            return envelope
        time.sleep(0.01)
    raise AssertionError(f"Agent run {run_id} did not reach {sorted(statuses)}")


class AgentRunManagerTests(unittest.TestCase):
    def manager(self, directory: Path, *, clock=time.monotonic, **extra) -> AgentRunManager:
        home = directory / "home"
        home.mkdir(exist_ok=True)
        fake_pi = write_fake_pi(directory)
        environ = {
            "HOME": str(home),
            "HERDR_HARNESS_AGENT_RUNS_ROOT": str(directory / "runs"),
            "HERDR_HARNESS_AGENT_PI_BIN": str(fake_pi),
            **extra,
        }
        return AgentRunManager(
            environ=environ,
            herdr_socket_path="/private/tmp/fake-herdr.sock",
            herdr_session="test-machine",
            clock=clock,
        )

    def test_list_models_parses_catalog_default_and_cache(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            marker_path = directory / "models-called.jsonl"
            settings_path = directory / "home" / ".pi" / "agent" / "settings.json"
            settings_path.parent.mkdir(parents=True)
            settings_path.write_text(
                json.dumps(
                    {
                        "defaultProvider": "openai-codex",
                        "defaultModel": "gpt-5.6-luna",
                    }
                ),
                encoding="utf-8",
            )
            clock = [0.0]
            manager = self.manager(
                directory,
                clock=lambda: clock[0],
                FAKE_LIST_MODELS_CAPTURE=str(marker_path),
            )

            first = manager.list_models()
            second = manager.list_models()

            self.assertEqual(first, second)
            self.assertEqual(first["default"], {"provider": "openai-codex", "id": "gpt-5.6-luna"})
            self.assertEqual(
                first["models"],
                [
                    {
                        "provider": "custom-lux-dspark",
                        "id": "qwen3.8-27b-nvfp4-dspark",
                        "contextWindow": 98300,
                        "supportsImages": False,
                        "reasoning": True,
                    },
                    {
                        "provider": "openai-codex",
                        "id": "gpt-5.6-luna",
                        "contextWindow": 272000,
                        "supportsImages": True,
                        "reasoning": True,
                    },
                    {
                        "provider": "other",
                        "id": "million",
                        "contextWindow": 1000000,
                        "supportsImages": False,
                        "reasoning": False,
                    },
                    {
                        "provider": "other",
                        "id": "literal",
                        "contextWindow": 16384,
                        "supportsImages": True,
                        "reasoning": False,
                    },
                ],
            )
            self.assertEqual(len(marker_path.read_text(encoding="utf-8").splitlines()), 1)

            clock[0] = 301.0
            manager.list_models()
            self.assertEqual(len(marker_path.read_text(encoding="utf-8").splitlines()), 2)
            manager.stop()

    def test_list_models_uses_fake_home_and_tolerates_unreadable_defaults(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            self.assertIsNone(manager.list_models()["default"])
            manager.stop()

            malformed = directory / "home" / ".pi" / "agent" / "settings.json"
            malformed.parent.mkdir(parents=True)
            malformed.write_text("not json", encoding="utf-8")
            manager = self.manager(directory)
            self.assertIsNone(manager.list_models()["default"])
            manager.stop()

    def test_list_models_reports_unavailable_catalogs(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            missing = AgentRunManager(
                environ={
                    "HERDR_HARNESS_AGENT_RUNS_ROOT": str(directory / "runs"),
                    "HERDR_HARNESS_AGENT_PI_BIN": str(directory / "no-such-pi-binary"),
                },
                herdr_socket_path="/private/tmp/fake-herdr.sock",
                herdr_session="test-machine",
            )
            with self.assertRaises(AgentRunError) as context:
                missing.list_models()
            self.assertEqual(context.exception.status, 502)
            self.assertEqual(context.exception.code, "agent_models_unavailable")
            missing.stop()

            empty = self.manager(
                directory,
                FAKE_LIST_MODELS_OUTPUT=(
                    "banner before table\\n"
                    "provider  model  context  max-out  thinking  images\\n"
                ),
            )
            with self.assertRaises(AgentRunError) as context:
                empty.list_models()
            self.assertEqual(context.exception.status, 502)
            self.assertEqual(context.exception.code, "agent_models_unavailable")
            empty.stop()

    def test_success_uses_private_cli_capable_pi_and_stable_public_shape(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(
                directory,
                FAKE_AGENT_CAPTURE=str(capture_path),
                HERDR_PANE_ID="must-not-leak",
            )

            started = manager.start(
                prompt="secret prompt about my panes",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={"machine": {"hostname": "mac"}, "panes": [{"id": "w1:p1"}]},
            )
            finished = wait_for_status(
                manager,
                started["run"]["id"],
                {"completed", "failed"},
            )

            self.assertEqual(set(started), {"ok", "run"})
            self.assertEqual(tuple(started["run"]), PUBLIC_RUN_KEYS)
            self.assertEqual(finished["run"]["status"], "completed")
            self.assertEqual(finished["run"]["response"], "Fleet answer")
            self.assertAlmostEqual(finished["run"]["costUSD"], 0.0123)
            session_file = Path(finished["run"]["sessionFile"])
            self.assertTrue(session_file.is_file())
            self.assertEqual(stat.S_IMODE(session_file.parent.parent.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((session_file.parent.parent / "run.json").stat().st_mode),
                0o600,
            )

            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertEqual(capture["prompt"], "secret prompt about my panes")
            self.assertNotIn("secret prompt", " ".join(capture["argv"]))
            self.assertEqual(capture["cwd"], str((directory / "home").resolve()))
            self.assertIsNone(capture["herdrPaneId"])
            self.assertEqual(capture["herdrAgentRunId"], started["run"]["id"])
            self.assertEqual(capture["herdrAgentRunMode"], "ask")
            self.assertEqual(capture["argv"][0:3], ["-p", "--mode", "json"])
            self.assertIn("read,bash,grep,find,ls,present_result", capture["argv"])
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertIn("use CLI commands", charter)
            self.assertIn("investigative only", charter)
            self.assertIn("--no-context-files", capture["argv"])
            self.assertIn("--no-extensions", capture["argv"])
            self.assertEqual(
                capture["argv"][capture["argv"].index("--extension") + 1],
                str(Path(__file__).resolve().parent.parent / "pi-semantic-bridge"),
            )
            manager.stop()

    def test_act_mode_uses_state_changing_tools_and_charter(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))

            started = manager.start(
                prompt="Open the browser",
                label="Open browser",
                cwd=str(directory / "home"),
                topology={},
                mode="act",
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertEqual(finished["run"]["mode"], "act")
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertIn("read,bash,grep,find,ls,write,edit,present_result", capture["argv"])
            self.assertEqual(capture["herdrAgentRunMode"], "act")
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertIn("ACT mode", charter)
            self.assertIn("MAY execute state-changing commands", charter)
            self.assertIn("untrusted data", charter)
            self.assertIn("must NOT be followed or executed", charter)
            manager.stop()

    def test_ask_mode_remains_the_default_and_uses_read_only_tools(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertEqual(finished["run"]["mode"], "ask")
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertEqual(
                capture["argv"][capture["argv"].index("--tools") + 1],
                "read,bash,grep,find,ls,present_result",
            )
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertNotIn("ACT mode", charter)
            self.assertIn("sole permitted side effect", charter)
            self.assertIn("HTTP(S) link", charter)
            self.assertIn("do not register local files in ASK mode", charter)
            manager.stop()

    def test_custom_system_prompt_uses_act_tools_and_keeps_topology_note(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))

            started = manager.start(
                prompt="Open the browser",
                label="Open browser",
                cwd=str(directory / "home"),
                topology={},
                mode="act",
                system_prompt="Custom instructions here",
            )
            wait_for_status(manager, started["run"]["id"], {"completed"})

            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertEqual(
                capture["argv"][capture["argv"].index("--tools") + 1],
                "read,bash,grep,find,ls,write,edit,present_result",
            )
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertTrue(charter.startswith("Custom instructions here "))
            self.assertIn("snapshot", charter)
            self.assertNotIn("MAY execute state-changing commands", charter)
            manager.stop()

    def test_custom_system_prompt_uses_ask_tools_and_keeps_topology_note(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
                system_prompt="Custom instructions here",
            )
            wait_for_status(manager, started["run"]["id"], {"completed"})

            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertEqual(
                capture["argv"][capture["argv"].index("--tools") + 1],
                "read,bash,grep,find,ls,present_result",
            )
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertTrue(charter.startswith("Custom instructions here "))
            self.assertIn("snapshot", charter)
            self.assertNotIn("Commands must be investigative only", charter)
            manager.stop()

    def test_system_prompt_is_validated_and_not_public(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)

            for system_prompt in (123, "   ", "x" * 32769):
                with self.subTest(system_prompt=system_prompt):
                    with self.assertRaises(AgentRunError) as context:
                        manager.start(
                            prompt="What changed?",
                            label="Fleet question",
                            cwd=str(directory / "home"),
                            topology={},
                            system_prompt=system_prompt,
                        )
                    self.assertEqual(context.exception.status, 400)
                    self.assertEqual(context.exception.code, "invalid_agent_system_prompt")

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
                system_prompt="Private instructions",
            )
            self.assertNotIn("systemPrompt", started["run"])
            self.assertNotIn("systemPrompt", manager.get(started["run"]["id"])["run"])
            manager.stop()

    def test_assistant_stream_error_marks_run_failed_and_surfaces_error_message(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="assistant-error")

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed", "failed"})

            self.assertEqual(finished["run"]["status"], "failed")
            self.assertEqual(finished["run"]["error"], "401 status code (no body)")
            self.assertFalse(finished["run"]["response"])
            manager.stop()

    def test_empty_response_completion_is_marked_failed_with_no_output_error(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="empty-text")

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed", "failed"})

            self.assertEqual(finished["run"]["status"], "failed")
            self.assertEqual(finished["run"]["error"], "agent produced no output")
            manager.stop()

    def test_real_text_followed_by_stream_error_stays_completed_with_text_kept(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="text-then-error")

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed", "failed"})

            self.assertEqual(finished["run"]["status"], "completed")
            self.assertEqual(finished["run"]["response"], "Partial answer")
            self.assertIsNone(finished["run"]["error"])
            manager.stop()

    def test_tool_start_and_end_produce_one_completed_step(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="tool-success")
            started = manager.start(
                prompt="Read the README",
                label="Read",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertEqual(len(finished["run"]["steps"]), 1)
            step = finished["run"]["steps"][0]
            self.assertEqual(step["toolCallId"], "call-1")
            self.assertEqual(step["toolName"], "read")
            self.assertEqual(step["argsPreview"], '{"path":"README.md"}')
            self.assertEqual(step["resultPreview"], "file contents")
            self.assertFalse(step["isError"])
            self.assertIsNotNone(step["startedAt"])
            self.assertIsNotNone(step["finishedAt"])
            self.assertFalse(step["truncated"])
            manager.stop()

    def test_tool_end_preserves_error_and_orphan_end_is_kept(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="tool-error")
            started = manager.start(
                prompt="Run false",
                label="Error",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})
            self.assertTrue(finished["run"]["steps"][0]["isError"])
            manager.stop()

            manager = self.manager(directory, FAKE_AGENT_MODE="tool-end-only")
            started = manager.start(
                prompt="Find matches",
                label="Orphan",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})
            step = finished["run"]["steps"][0]
            self.assertEqual(step["toolCallId"], "orphan")
            self.assertEqual(step["argsPreview"], "")
            self.assertEqual(step["resultPreview"], '{"matches":3}')
            self.assertIsNotNone(step["startedAt"])
            self.assertIsNotNone(step["finishedAt"])
            manager.stop()

    def test_tool_execution_updates_are_ignored_without_extra_writes(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)

            def run_and_count(mode=None):
                extra = {"FAKE_AGENT_MODE": mode} if mode else {}
                manager = self.manager(directory, **extra)
                writes = []
                original_write = manager._write

                def counting_write(run):
                    writes.append(run["id"])
                    original_write(run)

                manager._write = counting_write
                started = manager.start(
                    prompt="What changed?",
                    label="Updates",
                    cwd=str(directory / "home"),
                    topology={},
                )
                finished = wait_for_status(manager, started["run"]["id"], {"completed"})
                manager.stop()
                return finished, len(writes)

            baseline, baseline_writes = run_and_count()
            updated, updated_writes = run_and_count("tool-updates-only")

            self.assertEqual(baseline["run"]["steps"], [])
            self.assertEqual(updated["run"]["steps"], [])
            self.assertEqual(updated_writes, baseline_writes)

    def test_tool_steps_cap_and_preview_truncation(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="tool-cap")
            started = manager.start(
                prompt="Many reads",
                label="Cap",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})
            self.assertEqual(len(finished["run"]["steps"]), 200)
            self.assertTrue(finished["run"]["stepsTruncated"])
            manager.stop()

            manager = self.manager(directory, FAKE_AGENT_MODE="tool-long-arg")
            started = manager.start(
                prompt="Large read",
                label="Long arg",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})
            step = finished["run"]["steps"][0]
            self.assertEqual(len(step["argsPreview"]), 400)
            self.assertTrue(step["truncated"])
            manager.stop()

    def test_malformed_tool_args_do_not_stop_stdout_capture(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="tool-malformed-arg")
            started = manager.start(
                prompt="Read safely",
                label="Malformed",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            step = finished["run"]["steps"][0]
            self.assertEqual(step["argsPreview"], "")
            self.assertEqual(step["resultPreview"], "ok")
            self.assertEqual(finished["run"]["response"], "Fleet answer")
            manager.stop()

    def test_tool_step_burst_is_debounced(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="tool-burst")
            writes = []
            original_write = manager._write

            def counting_write(run):
                writes.append(run["id"])
                original_write(run)

            manager._write = counting_write
            started = manager.start(
                prompt="Burst",
                label="Burst",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertEqual(len(finished["run"]["steps"]), 50)
            self.assertLess(len(writes), 15)
            manager.stop()

    def test_model_and_thinking_level_are_stored_and_appended_to_argv(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))
            model = "accounts/fireworks/models/deepseek-v4-flash-0731"

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
                model=model,
                thinking_level="high",
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertEqual(finished["run"]["model"], model)
            self.assertEqual(finished["run"]["thinkingLevel"], "high")
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertEqual(capture["argv"][capture["argv"].index("--model") + 1], model)
            self.assertEqual(capture["argv"][capture["argv"].index("--thinking") + 1], "high")
            manager.stop()

    def test_invalid_model_and_thinking_level_are_rejected(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)

            with self.assertRaises(AgentRunError) as context:
                manager.start(
                    prompt="What changed?",
                    label="Fleet question",
                    cwd=str(directory / "home"),
                    topology={},
                    model="bad model with spaces",
                )
            self.assertEqual(context.exception.status, 400)

            with self.assertRaises(AgentRunError) as context:
                manager.start(
                    prompt="What changed?",
                    label="Fleet question",
                    cwd=str(directory / "home"),
                    topology={},
                    thinking_level="ultra",
                )
            self.assertEqual(context.exception.status, 400)
            manager.stop()

    def test_attachments_are_written_to_run_dir_and_appended_as_at_args(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))
            data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL2NwAAAABJRU5ErkJggg==")

            started = manager.start(
                prompt="Look at this",
                label="Image question",
                cwd=str(directory / "home"),
                topology={},
                attachments=[
                    {"filename": "photo.png", "dataBase64": base64.b64encode(data).decode()}
                ],
            )
            run_id = started["run"]["id"]
            finished = wait_for_status(manager, run_id, {"completed"})
            attachment_path = manager.runs_root / run_id / "attachments" / "photo.png"

            self.assertEqual(attachment_path.read_bytes(), data)
            self.assertEqual(finished["run"]["attachments"], ["photo.png"])
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertIn("@" + str(attachment_path), capture["argv"])
            manager.stop()

    def test_duplicate_attachment_filenames_are_deduped_with_a_numeric_suffix(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            first = b"first image"
            second = b"second image"

            started = manager.start(
                prompt="Look at these",
                label="Image question",
                cwd=str(directory / "home"),
                topology={},
                attachments=[
                    {"filename": "photo.png", "dataBase64": base64.b64encode(first).decode()},
                    {"filename": "photo.png", "dataBase64": base64.b64encode(second).decode()},
                ],
            )
            run_id = started["run"]["id"]
            finished = wait_for_status(manager, run_id, {"completed"})
            attachments_dir = manager.runs_root / run_id / "attachments"

            self.assertEqual(finished["run"]["attachments"], ["photo.png", "photo-1.png"])
            self.assertEqual((attachments_dir / "photo.png").read_bytes(), first)
            self.assertEqual((attachments_dir / "photo-1.png").read_bytes(), second)
            manager.stop()

    def test_case_and_unicode_normalization_variants_are_deduped_too(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            first = b"first image"
            second = b"second image"

            started = manager.start(
                prompt="Look at these",
                label="Image question",
                cwd=str(directory / "home"),
                topology={},
                attachments=[
                    {"filename": "Photo.png", "dataBase64": base64.b64encode(first).decode()},
                    {"filename": "photo.png", "dataBase64": base64.b64encode(second).decode()},
                ],
            )
            run_id = started["run"]["id"]
            finished = wait_for_status(manager, run_id, {"completed"})
            attachments_dir = manager.runs_root / run_id / "attachments"

            self.assertEqual(finished["run"]["attachments"], ["Photo.png", "photo-1.png"])
            self.assertEqual((attachments_dir / "Photo.png").read_bytes(), first)
            self.assertEqual((attachments_dir / "photo-1.png").read_bytes(), second)
            manager.stop()

    def test_invalid_attachments_are_rejected(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            valid_data = base64.b64encode(b"image").decode()
            options = {
                "prompt": "Look at this",
                "label": "Image question",
                "cwd": str(directory / "home"),
                "topology": {},
            }

            for attachments, status in (
                ([{"filename": "malware.exe", "dataBase64": valid_data}], 400),
                (
                    [
                        {
                            "filename": "photo.png",
                            "dataBase64": base64.b64encode(
                                b"a" * (21 * 1024 * 1024)
                            ).decode(),
                        }
                    ],
                    413,
                ),
                ([{"filename": "../evil.png", "dataBase64": valid_data}], 400),
            ):
                with self.assertRaises(AgentRunError) as context:
                    manager.start(**options, attachments=attachments)
                self.assertEqual(context.exception.status, status)
            manager.stop()

    def test_attachment_filename_rejects_excessive_utf16_units(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            filename = "🎉" * 130 + ".png"
            self.assertLessEqual(len(filename), 200)
            self.assertGreater(len(filename.encode("utf-16-le")) // 2, 240)

            with self.assertRaises(AgentRunError) as context:
                manager.start(
                    prompt="Look at this",
                    label="Image question",
                    cwd=str(directory / "home"),
                    topology={},
                    attachments=[
                        {
                            "filename": filename,
                            "dataBase64": base64.b64encode(b"image").decode(),
                        }
                    ],
                )

            self.assertEqual(context.exception.status, 400)
            manager.stop()

    def test_no_new_fields_means_identical_behavior_to_today(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            capture_path = directory / "capture.json"
            manager = self.manager(directory, FAKE_AGENT_CAPTURE=str(capture_path))

            started = manager.start(
                prompt="What changed?",
                label="Fleet question",
                cwd=str(directory / "home"),
                topology={},
            )
            finished = wait_for_status(manager, started["run"]["id"], {"completed"})

            self.assertIsNone(finished["run"]["model"])
            self.assertIsNone(finished["run"]["thinkingLevel"])
            self.assertEqual(finished["run"]["attachments"], [])
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            self.assertNotIn("--model", capture["argv"])
            self.assertNotIn("--thinking", capture["argv"])
            self.assertFalse(any(item.startswith("@") for item in capture["argv"]))
            manager.stop()

    def test_invalid_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)

            with self.assertRaises(AgentRunError) as context:
                manager.start(
                    prompt="What changed?",
                    label="Fleet question",
                    cwd=str(directory / "home"),
                    topology={},
                    mode="bogus",
                )

            self.assertEqual(context.exception.status, 400)
            manager.stop()

    def test_old_run_without_mode_surfaces_ask(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            runs_root = directory / "runs"
            run_id = "agr_000000000001"
            run_dir = runs_root / run_id
            run_dir.mkdir(parents=True)
            (run_dir / "run.json").write_text(
                json.dumps({"id": run_id, "status": "completed"}),
                encoding="utf-8",
            )
            manager = AgentRunManager(
                environ={"HERDR_HARNESS_AGENT_RUNS_ROOT": str(runs_root)},
                herdr_socket_path="/tmp/fake.sock",
                herdr_session="test",
            )

            public = manager.get(run_id)["run"]
            self.assertEqual(public["mode"], "ask")
            self.assertEqual(public["steps"], [])
            self.assertFalse(public["stepsTruncated"])
            manager.stop()

    def test_cancel_and_noncompleted_promotion_are_safe(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, FAKE_AGENT_MODE="hang")
            started = manager.start(
                prompt="wait",
                label="Wait",
                cwd=str(directory / "home"),
                topology={},
            )
            run_id = started["run"]["id"]
            wait_for_status(manager, run_id, {"running"})

            with self.assertRaises(AgentRunError) as context:
                manager.promotable(run_id)
            self.assertEqual(context.exception.status, 409)

            cancelled = manager.cancel(run_id)
            self.assertEqual(cancelled["run"]["status"], "cancelled")
            manager.stop()

    def test_timeout_terminates_pi_and_records_a_terminal_failure(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(
                directory,
                FAKE_AGENT_MODE="hang",
                HERDR_HARNESS_AGENT_TIMEOUT_SECONDS="1",
            )
            started = manager.start(
                prompt="take too long",
                label="Timeout",
                cwd=str(directory / "home"),
                topology={},
            )

            failed = wait_for_status(manager, started["run"]["id"], {"failed"})

            self.assertIn("within 1 seconds", failed["run"]["error"])
            self.assertIsNotNone(failed["run"]["finishedAt"])
            manager.stop()

    def test_restart_recovery_and_ttl_remove_unpromoted_artifacts(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            runs_root = directory / "runs"
            queued_id = "agr_000000000001"
            expired_id = "agr_000000000002"
            for run_id, status in ((queued_id, "queued"), (expired_id, "completed")):
                run_dir = runs_root / run_id
                (run_dir / "sessions").mkdir(parents=True)
                (run_dir / "sessions" / "artifact.jsonl").write_text("private")
                (run_dir / "run.json").write_text(
                    json.dumps(
                        {
                            "id": run_id,
                            "status": status,
                            "finishedAt": "2000-01-01T00:00:00Z" if status == "completed" else None,
                        }
                    ),
                    encoding="utf-8",
                )
            manager = AgentRunManager(
                environ={
                    "HERDR_HARNESS_AGENT_RUNS_ROOT": str(runs_root),
                    "HERDR_HARNESS_AGENT_TTL_SECONDS": "60",
                },
                herdr_socket_path="/tmp/fake.sock",
                herdr_session="test",
            )

            self.assertEqual(manager.get(queued_id)["run"]["status"], "failed")
            self.assertFalse((runs_root / expired_id).exists())
            manager.stop()

    def test_delete_never_removes_a_promoted_session(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            started = manager.start(
                prompt="keep this history",
                label="Keep",
                cwd=str(directory / "home"),
                topology={},
            )
            completed = wait_for_status(manager, started["run"]["id"], {"completed"})
            session_file = Path(completed["run"]["sessionFile"])
            manager.mark_promoted(
                started["run"]["id"],
                workspace_id="w1",
                pane_id="w1:p1",
            )

            deleted = manager.delete(started["run"]["id"])

            self.assertEqual(deleted["run"]["status"], "promoted")
            self.assertTrue(session_file.is_file())
            retained = manager.get(started["run"]["id"])["run"]
            self.assertEqual(retained["status"], "promoted")
            self.assertEqual(retained["prompt"], "")
            manager.stop()

    def test_new_run_is_its_own_thread_root_and_publicly_serialized(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)

            started = manager.start(
                prompt="Start a thread",
                label="Thread",
                cwd=str(directory / "home"),
                topology={},
            )

            self.assertEqual(started["run"]["threadRootRunId"], started["run"]["id"])
            self.assertIn("threadRootRunId", started["run"])
            wait_for_status(manager, started["run"]["id"], {"completed"})
            manager.stop()

    def test_continuation_inherits_the_root_session_and_cwd(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            alternate_cwd = directory / "alternate"
            alternate_cwd.mkdir()
            manager = self.manager(directory)
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                )["run"]["id"],
                {"completed"},
            )["run"]

            continued = manager.start(
                prompt="Second turn",
                label="Thread",
                cwd=str(alternate_cwd),
                topology={},
                continue_from_run_id=root["id"],
            )["run"]
            raw_continued = manager._read(continued["id"])

            self.assertEqual(continued["threadRootRunId"], root["id"])
            self.assertEqual(continued["sessionId"], root["sessionId"])
            self.assertEqual(raw_continued["sessionsDir"], manager._read(root["id"])["sessionsDir"])
            self.assertEqual(raw_continued["cwd"], str((directory / "home").resolve()))
            wait_for_status(manager, continued["id"], {"completed"})
            manager.stop()

    def test_continuation_of_a_continuation_keeps_the_original_root(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn", label="Thread", cwd=str(directory / "home"), topology={}
                )["run"]["id"],
                {"completed"},
            )["run"]
            middle = wait_for_status(
                manager,
                manager.start(
                    prompt="Second turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]

            third = manager.start(
                prompt="Third turn",
                label="Thread",
                cwd=str(directory / "home"),
                topology={},
                continue_from_run_id=middle["id"],
            )["run"]

            self.assertEqual(third["threadRootRunId"], root["id"])
            self.assertEqual(third["sessionId"], root["sessionId"])
            wait_for_status(manager, third["id"], {"completed"})
            manager.stop()

    def test_missing_continuation_source_starts_a_fresh_thread(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)

            started = manager.start(
                prompt="Fresh after reaping",
                label="Thread",
                cwd=str(directory / "home"),
                topology={},
                continue_from_run_id="agr_0123456789ab",
            )["run"]

            self.assertEqual(started["threadRootRunId"], started["id"])
            wait_for_status(manager, started["id"], {"completed"})
            manager.stop()

    def test_turn_two_is_promotable_from_the_root_session_directory(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn", label="Thread", cwd=str(directory / "home"), topology={}
                )["run"]["id"],
                {"completed"},
            )["run"]
            second = wait_for_status(
                manager,
                manager.start(
                    prompt="Second turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]

            _, session_file = manager.promotable(second["id"])

            self.assertEqual(session_file, root["sessionFile"])
            manager.stop()

    def test_thread_delete_cascades_only_from_the_root(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn", label="Thread", cwd=str(directory / "home"), topology={}
                )["run"]["id"],
                {"completed"},
            )["run"]
            follower = wait_for_status(
                manager,
                manager.start(
                    prompt="Second turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]

            manager.delete(follower["id"])
            self.assertTrue((manager.runs_root / root["id"]).is_dir())
            self.assertFalse((manager.runs_root / follower["id"]).exists())

            final_follower = wait_for_status(
                manager,
                manager.start(
                    prompt="Final turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]
            manager.delete(root["id"])

            self.assertFalse((manager.runs_root / root["id"]).exists())
            self.assertFalse((manager.runs_root / final_follower["id"]).exists())
            manager.stop()

    def test_thread_root_is_preserved_when_any_turn_is_promoted(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory)
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn", label="Thread", cwd=str(directory / "home"), topology={}
                )["run"]["id"],
                {"completed"},
            )["run"]
            follower = wait_for_status(
                manager,
                manager.start(
                    prompt="Second turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]
            manager.mark_promoted(follower["id"], workspace_id="w1", pane_id="w1:p1")

            manager.delete(root["id"])

            self.assertTrue((manager.runs_root / root["id"]).is_dir())
            self.assertTrue((manager.runs_root / follower["id"]).is_dir())
            self.assertEqual(manager.get(root["id"])["run"]["prompt"], "")
            manager.stop()

    def test_thread_ttl_is_rolling_and_reaps_stale_threads_as_a_unit(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            manager = self.manager(directory, HERDR_HARNESS_AGENT_TTL_SECONDS="60")
            root = wait_for_status(
                manager,
                manager.start(
                    prompt="First turn", label="Thread", cwd=str(directory / "home"), topology={}
                )["run"]["id"],
                {"completed"},
            )["run"]
            follower = wait_for_status(
                manager,
                manager.start(
                    prompt="Second turn",
                    label="Thread",
                    cwd=str(directory / "home"),
                    topology={},
                    continue_from_run_id=root["id"],
                )["run"]["id"],
                {"completed"},
            )["run"]
            old = "2000-01-01T00:00:00Z"
            root_record = manager._read(root["id"])
            follower_record = manager._read(follower["id"])
            root_record["finishedAt"] = old
            follower_record["finishedAt"] = manager._now()
            manager._write(root_record)
            manager._write(follower_record)

            manager.prune()

            self.assertTrue((manager.runs_root / root["id"]).is_dir())
            self.assertTrue((manager.runs_root / follower["id"]).is_dir())
            follower_record = manager._read(follower["id"])
            follower_record["finishedAt"] = old
            manager._write(follower_record)
            manager.prune()

            self.assertFalse((manager.runs_root / root["id"]).exists())
            self.assertFalse((manager.runs_root / follower["id"]).exists())
            manager.stop()


class AgentRunServiceTests(unittest.TestCase):
    def test_current_fleet_context_and_promotion_resume_the_exact_session(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            home = directory / "home"
            home.mkdir()
            extension = directory / "bridge"
            extension.mkdir()
            fake_pi = write_fake_pi(directory)
            environ = {
                "HOME": str(home),
                "HERDR_HARNESS_AGENT_RUNS_ROOT": str(directory / "runs"),
                "HERDR_HARNESS_AGENT_PI_BIN": str(fake_pi),
                "HERDR_HARNESS_PI_EXTENSION_PATH": str(extension),
            }
            manager = AgentRunManager(
                environ=environ,
                herdr_socket_path="/tmp/fake.sock",
                herdr_session="fleet-machine",
            )
            snapshot = {
                "focused_workspace_id": "w1",
                "focused_pane_id": "w1:p1",
                "workspaces": [{"workspace_id": "w1", "label": "Fleet"}],
                "panes": [
                    {
                        "pane_id": "w1:p1",
                        "workspace_id": "w1",
                        "title": "Auth agent",
                        "agent": "pi",
                        "agent_status": "working",
                        "cwd": str(home),
                        "revision": 7,
                    }
                ],
                "agents": [],
                "tabs": [],
                "layouts": [],
            }
            client = FakeQuickSessionClient(
                snapshot,
                {
                    "tab.create": {
                        "tab": {
                            "tab_id": "w1:t2",
                            "root_pane": {"pane_id": "w1:p2", "tab_id": "w1:t2"},
                        }
                    }
                },
            )
            semantic = FakeReadyPiSemantic()
            service = HerdrService(
                client,
                environ=environ,
                agent_runs=manager,
                pi_semantic=semantic,
            )
            service.refresh_snapshot()

            started = service.start_agent_run(prompt="What is auth doing?")
            run_id = started["run"]["id"]
            context = json.loads(
                (manager.runs_root / run_id / "topology.json").read_text(encoding="utf-8")
            )
            self.assertEqual(context["machine"]["herdrSession"], "quick-session-fixtures")
            self.assertEqual(context["panes"][0]["title"], "Auth agent")
            self.assertEqual(context["panes"][0]["status"], "working")
            self.assertIsNotNone(context["panes"][0]["workingSince"])
            completed = wait_for_status(manager, run_id, {"completed"})
            with Path(completed["run"]["sessionFile"]).open(encoding="utf-8") as handle:
                semantic.session_id = json.loads(handle.readline())["id"]

            promoted = service.promote_agent_run(run_id, workspace_id="w1")

            self.assertEqual(promoted["run"]["status"], "promoted")
            tab_request = next(params for method, params in client.requests if method == "tab.create")
            self.assertEqual(tab_request["cwd"], str(home.resolve()))
            self.assertNotIn("label", tab_request)
            start_request = next(params for method, params in client.requests if method == "agent.start")
            self.assertEqual(
                start_request["args"],
                ["--session", completed["run"]["sessionFile"], "--extension", str(extension)],
            )
            manager.stop()


if __name__ == "__main__":
    unittest.main()
