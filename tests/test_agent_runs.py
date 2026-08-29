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

            prompt = sys.stdin.read()
            capture_path = os.environ.get("FAKE_AGENT_CAPTURE")
            if capture_path:
                Path(capture_path).write_text(json.dumps({
                    "argv": sys.argv[1:],
                    "prompt": prompt,
                    "cwd": os.getcwd(),
                    "herdrPaneId": os.environ.get("HERDR_PANE_ID"),
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
    def manager(self, directory: Path, **extra) -> AgentRunManager:
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
        )

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
            self.assertEqual(capture["argv"][0:3], ["-p", "--mode", "json"])
            self.assertIn("read,bash,grep,find,ls", capture["argv"])
            charter = capture["argv"][capture["argv"].index("--append-system-prompt") + 1]
            self.assertIn("use CLI commands", charter)
            self.assertIn("investigative only", charter)
            self.assertIn("--no-context-files", capture["argv"])
            self.assertIn("--no-extensions", capture["argv"])
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
