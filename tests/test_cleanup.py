import copy
import json
import os
import tempfile
import textwrap
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from herdr_harness.alerts import AlertStore
from herdr_harness.cleanup import (
    CleanupError,
    CleanupManager,
    _age_int,
    _rail_pane,
    _rail_workspace,
    _resolve_pi_bin,
    pi_sessions_root,
    resolve_pi_cost,
    session_slug,
)
from herdr_harness.pi_semantic import PI_SEMANTIC_PROTOCOL
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService
from herdr_harness.stars import StarStore


def snapshot(revision=1, status="done"):
    return snapshot_with_panes([("w1:p1", revision, status)])


def snapshot_with_panes(panes):
    return {
        "focused_workspace_id": None,
        "workspaces": [{"workspace_id": "w1", "label": "One", "focused": False}],
        "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "label": "One"}],
        "panes": [
            {
                "pane_id": pane_id,
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "agent_status": status,
                "revision": revision,
                "focused": False,
                "title": pane_id,
            }
            for pane_id, revision, status in panes
        ],
        "agents": [],
        "layouts": [],
    }


def pi_cleanup_snapshot(pane_ids=("w1:p1",)):
    value = snapshot_with_panes([(pane_id, 1, "done") for pane_id in pane_ids])
    for pane in value["panes"]:
        pane.update({"agent": "pi", "cwd": "/tmp/cleanup-pi", "foreground_cwd": "/tmp/cleanup-pi"})
    value["agents"] = [
        {
            "pane_id": pane_id,
            "workspace_id": "w1",
            "agent": "pi",
            "agent_status": "done",
        }
        for pane_id in pane_ids
    ]
    return value


class FakeClient:
    socket_path = "/private/tmp/cleanup-test.sock"
    session = "cleanup-tests"

    def __init__(self, snapshots, request_hook=None):
        self.snapshots = [copy.deepcopy(item) for item in snapshots]
        self.last = copy.deepcopy(snapshots[-1])
        self.requests = []
        self.request_hook = request_hook

    def snapshot(self):
        if self.snapshots:
            self.last = self.snapshots.pop(0)
        return copy.deepcopy(self.last)

    def request(self, method, params):
        self.requests.append((method, copy.deepcopy(params)))
        if self.request_hook is not None:
            self.request_hook(method, params)
        if method == "pane.read":
            return {"read": {"text": "finished\n$ ", "truncated": False}}
        return {"ok": True}

    def subscribe_forever(self, *_args, **_kwargs):
        return None


def write_fake_pi(directory):
    """Write a configurable JSON-mode Pi replacement for cleanup tests."""
    path = Path(directory) / "fake-pi.py"
    path.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env python3
            import json
            import os
            import re
            import sys
            import time

            mode = os.environ.get("FAKE_PI_MODE", "valid")
            argv_path = os.environ.get("FAKE_PI_ARGV_FILE")
            if argv_path:
                with open(argv_path, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(sys.argv) + "\\n")
            path_path = os.environ.get("FAKE_PI_PATH_FILE")
            if path_path:
                with open(path_path, "w", encoding="utf-8") as handle:
                    handle.write(os.environ.get("PATH", ""))
            counter_path = os.environ.get("FAKE_PI_COUNTER_FILE")
            invocation = 0
            if counter_path:
                try:
                    with open(counter_path, "r", encoding="utf-8") as handle:
                        invocation = int(handle.read() or "0")
                except (OSError, ValueError):
                    invocation = 0
                invocation += 1
                with open(counter_path, "w", encoding="utf-8") as handle:
                    handle.write(str(invocation))

            if mode == "hang":
                time.sleep(3600)
            if mode == "slow":
                time.sleep(1.5)
            if mode == "stderr_invalid":
                print("No API key found for fireworks.", file=sys.stderr, flush=True)
            elif mode == "retry" and invocation == 1:
                print("not json at all", flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            elif mode == "schema_retry" and invocation == 1:
                text = "```json\\n" + json.dumps({"verdict": "stale", "reason": "looks idle"}) + "\\n```"
                print(json.dumps({"type": "message_end", "message": {"text": text}}), flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            else:
                reason = "finished"
                evidence_cited = ["tail.txt"]
                pane_ids = list(dict.fromkeys(re.findall(r'"paneId":\\s*"([^"]+)"', sys.argv[-1]))) or ["w1:p1"]
                if mode == "wrong_pane_retry" and invocation == 1:
                    pane_ids = ["w9:p9"]
                if mode == "percent_encoded":
                    pane_ids = ["w1%3Ap1"]
                if mode == "verbose":
                    reason = ("judge supplied pane content\\n" * 900)
                    evidence_cited = [("citation from pane output\\n" * 20) for _ in range(50)]
                verdict = {
                    "workspaceId": "w1",
                    "workspaceCloseRecommended": mode in {"workspace", "workspace_child_keep"} or (mode == "workspace_mixed" and invocation == 1),
                    "workspaceReason": "All reviewed panes are complete and quiet.",
                    "summary": "Workspace One contains completed cleanup-test work.",
                    "panes": [
                        {
                            "paneId": pane_id,
                            "classification": "completed",
                            "closeRecommended": mode != "workspace_child_keep",
                            "confidence": 0.95,
                            "summary": "The pane completed its assigned cleanup-test task.",
                            "reason": reason,
                            "evidenceCited": evidence_cited,
                        }
                        for pane_id in pane_ids
                    ],
                }
                text = "```json\\n" + json.dumps(verdict) + "\\n```"
                print(json.dumps({"type": "message_end", "message": {"role": "assistant", "text": text, "usage": {"cost": {"total": 0.00165}}}}), flush=True)
                print(json.dumps({"type": "agent_end"}), flush=True)
            """
        ),
        encoding="utf-8",
    )
    os.chmod(path, 0o755)
    return path


def wait_for_run(test_case, manager, run_id, timeout=10):
    """Return a terminal cleanup run or fail the calling test at timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        run = manager.get_run(run_id)
        if run["run"]["status"] in {"done", "partial", "failed", "applied"}:
            cleanup_threads = [
                thread
                for thread in threading.enumerate()
                if thread.name == f"cleanup-{run_id}" and thread.is_alive()
            ]
            for thread in cleanup_threads:
                remaining = deadline - time.monotonic()
                thread.join(timeout=max(0, remaining))
                if thread.is_alive():
                    test_case.fail(
                        f"cleanup thread for run {run_id} did not finish within {timeout} seconds"
                    )
            return run
        time.sleep(0.01)
    test_case.fail(f"cleanup run {run_id} did not finish within {timeout} seconds")


class CleanupPureTests(unittest.TestCase):
    def test_age_int_rounds_fractional_ages_and_preserves_none(self):
        done_alert_age = _age_int(369398.1364490986)
        session_file_age = _age_int(529216.9183209419)

        self.assertEqual(done_alert_age, 369398)
        self.assertEqual(session_file_age, 529217)
        self.assertIs(type(done_alert_age), int)
        self.assertIs(type(session_file_age), int)
        self.assertIsNone(_age_int(None))

    def test_resolve_pi_bin_prefers_env_override(self):
        self.assertEqual(
            _resolve_pi_bin({'HERDR_HARNESS_CLEANUP_PI_BIN': '/some/value'}),
            '/some/value',
        )

    def test_resolve_pi_bin_uses_path_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            pi = Path(directory) / 'pi'
            pi.write_text('#!/bin/sh\n')
            os.chmod(pi, 0o755)

            resolved = _resolve_pi_bin({'PATH': directory})

            self.assertEqual(os.path.realpath(resolved), os.path.realpath(pi))

    def test_resolve_pi_bin_uses_candidate_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pi = root / 'candidate-pi'
            pi.write_text('#!/bin/sh\n')
            os.chmod(pi, 0o755)

            resolved = _resolve_pi_bin(
                {'PATH': str(root / 'empty')},
                candidates=[root / 'missing-pi', pi],
            )

            self.assertEqual(resolved, str(pi))

    def test_resolve_pi_bin_returns_none_when_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(_resolve_pi_bin({'PATH': directory}, candidates=[]))

    def test_session_cost_resolution_and_environment_precedence(self):
        self.assertEqual(
            session_slug("/Users/ronnierocha/projects/cmux-orchestrator"),
            "--Users-ronnierocha-projects-cmux-orchestrator--",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            slug = root / session_slug("/Users/a/b")
            slug.mkdir()
            (slug / "one.jsonl").write_text(
                "\n".join(
                    [
                        json.dumps({"type": "message", "message": {"role": "user", "content": []}}),
                        json.dumps({"type": "message", "message": {"role": "assistant", "usage": {"totalTokens": 4, "cost": {"total": 0.03}}}}),
                        json.dumps({"type": "message", "message": {"role": "assistant", "usage": {"totalTokens": 5, "cost": {"total": 0.05}}}}),
                    ]
                )
            )
            environ = {"PI_CODING_AGENT_SESSION_DIR": directory, "PI_CODING_AGENT_DIR": "/ignored"}
            self.assertEqual(pi_sessions_root(environ), root)
            cost = resolve_pi_cost({"session": {}}, {"foreground_cwd": "/Users/a/b"}, environ)
            self.assertAlmostEqual(cost["costUSD"], 0.08)
            self.assertEqual(cost["totalTokens"], 9)
            self.assertEqual(cost["costSource"], "sessionFile")
            bridge = resolve_pi_cost(
                {"usage": {"costUSD": 1.23, "totalTokens": 456}, "session": {"file": str(slug / "one.jsonl")}},
                {},
                environ,
            )
            self.assertEqual(bridge["costSource"], "bridge")
            self.assertEqual(bridge["costUSD"], 1.23)
            self.assertEqual(bridge["sessionFile"], str(slug / "one.jsonl"))
            self.assertIsInstance(bridge["sessionFileAgeSeconds"], int)

    def test_rails_have_exact_codes(self):
        baseline = {
            "agentStatus": "done",
            "focused": False,
            "focusedWorkspace": False,
            "starred": False,
            "revisionChanged": False,
            "piWorking": False,
            "unreadAlerts": 0,
        }
        cases = [
            ("agentStatus", "working", "R1:working"),
            ("agentStatus", "blocked", "R1:blocked"),
            ("focused", True, "R2:focused"),
            ("focusedWorkspace", True, "R2:focused_workspace"),
            ("starred", True, "R3:starred"),
            ("revisionChanged", True, "R4:active_output"),
            ("piWorking", True, "R1:working"),
            ("unreadAlerts", 1, "R5:unread_alerts"),
        ]
        for key, value, expected in cases:
            signals = dict(baseline)
            signals[key] = value
            self.assertEqual(
                _rail_pane(signals, {"minConfidence": 0.6}, {"confidence": 0.9}),
                [expected],
            )
        self.assertEqual(_rail_pane(baseline, {"minConfidence": 0.6}, {"confidence": 0.1}), ["R7:low_confidence"])
        self.assertEqual(_rail_workspace({"state": "dirty"}, False), ["R6:git_dirty"])
        self.assertEqual(_rail_workspace({"state": "unpushed"}, False), ["R6:git_unpushed"])
        self.assertEqual(_rail_workspace({"state": "unavailable"}, False), ["R6:git_unknown"])
        self.assertEqual(_rail_workspace({"state": "clean"}, True), ["R6:pane_blocked"])

    def test_expected_pi_disconnect_still_rejects_replacement_session_identity(self):
        old = {
            "_sessionIdAtReport": "session-a",
            "piSession": {"active": True, "sessionId": "session-a"},
        }
        self.assertFalse(CleanupManager._session_changed(
            old,
            {"active": False, "connected": False, "sessionId": "session-a"},
            allow_expected_disconnect=True,
        ))
        self.assertTrue(CleanupManager._session_changed(
            old,
            {"active": False, "connected": False, "sessionId": "session-b"},
            allow_expected_disconnect=True,
        ))


class CleanupManagerTests(unittest.TestCase):
    def _pi_cleanup_run(self, directory, pane_ids=("w1:p1",), *, disconnect_on_quit=True, mode="valid"):
        fake_pi = write_fake_pi(directory)
        snap = pi_cleanup_snapshot(pane_ids)
        holder = {}

        def request_hook(method, params):
            if method == "pane.send_input" and disconnect_on_quit:
                service = holder["service"]
                service.pi_semantic.journal.mark_connected(
                    params["pane_id"],
                    False,
                    namespace=service.pi_semantic.namespace,
                )

        client = FakeClient([snap] * 16, request_hook=request_hook)
        environ = {
            "HERDR_HARNESS_CLEANUP_RUNS_ROOT": str(Path(directory) / "runs"),
            "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
            "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
            "HERDR_HARNESS_CLEANUP_PI_QUIT_TIMEOUT": "0",
            "HERDR_HARNESS_CLEANUP_MAX_RUNS": "1",
            "FAKE_PI_MODE": mode,
        }
        service = HerdrService(client, environ=environ)
        service.workspace_git_status = lambda _workspace_id: {
            "staged": False,
            "unstaged": False,
            "untracked": False,
        }
        holder["service"] = service
        service.refresh_snapshot()
        for index, pane_id in enumerate(pane_ids, 1):
            session_file = Path(directory) / f"session-{index}.jsonl"
            session_file.write_text(
                json.dumps({
                    "type": "message",
                    "message": {"role": "assistant", "usage": {"totalTokens": index * 100, "cost": {"total": index / 10}}},
                }) + "\n"
            )
            session_id = f"pi-session-{index}"
            service.pi_semantic.journal.ingest(
                pane_id,
                {
                    "protocol": dict(PI_SEMANTIC_PROTOCOL),
                    "pane_id": pane_id,
                    "instance_id": f"bridge-{index}",
                    "sequence": 1,
                    "kind": "snapshot",
                    "generated_at": "2026-08-24T00:00:00Z",
                    "session_id": session_id,
                    "snapshot": {
                        "session": {"id": session_id, "file": str(session_file), "name": f"Cleanup {index}"},
                        "state": {"idle": True},
                        "usage": {"costUSD": index / 10, "totalTokens": index * 100},
                        "entries": [],
                    },
                },
                namespace=service.pi_semantic.namespace,
            )
            service.pi_semantic.journal.mark_connected(
                pane_id,
                True,
                namespace=service.pi_semantic.namespace,
            )
        run_id = service.cleanup.start_run({"keepEvidence": True})["runId"]
        wait_for_run(self, service.cleanup, run_id)
        return service, run_id

    def test_get_run_uses_a_live_nested_envelope(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "slow",
                },
            )
            run_id = service.cleanup.start_run({})["runId"]
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                envelope = service.cleanup.get_run(run_id)
                if envelope["run"]["status"] in {"collecting", "judging"}:
                    break
                time.sleep(0.01)
            else:
                self.fail("run did not expose an active state")
            self.assertTrue(envelope["ok"])
            self.assertNotIn("status", envelope)
            self.assertIsInstance(envelope["run"]["phaseHistory"], list)
            self.assertIsInstance(envelope["run"]["config"]["model"], str)
            finished = wait_for_run(self, service.cleanup, run_id)
            self.assertEqual(finished["run"]["progress"]["done"], finished["run"]["progress"]["total"])

    def test_start_run_stores_and_validates_judge_charter(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            run_id = service.cleanup.start_run(
                {"judgeCharter": "My custom judge instructions."}
            )["runId"]
            run = service.cleanup.get_run(run_id)
            self.assertEqual(run["run"]["config"]["judgeCharter"], "My custom judge instructions.")
            wait_for_run(self, service.cleanup, run_id)

            for judge_charter in ("   ", "x" * 32769, 123):
                with self.subTest(judge_charter=judge_charter):
                    with self.assertRaises(CleanupError) as context:
                        service.cleanup.start_run({"judgeCharter": judge_charter})
                    self.assertEqual(context.exception.code, "invalid_request")
                    self.assertEqual(context.exception.status, 400)

    def test_get_run_normalizes_required_decoder_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            service = HerdrService(FakeClient([snapshot()]), environ={"HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory})
            run_id = "clr_0123456789ab"
            run_dir = Path(directory) / run_id
            run_dir.mkdir()
            (run_dir / "run.json").write_text(json.dumps({
                "runId": run_id,
                "status": "done",
                "config": {"model": None},
                "progress": [],
                "phaseHistory": {},
            }))
            (run_dir / "report.json").write_text(json.dumps({"run": {"judge": {}}}))
            envelope = service.cleanup.get_run(run_id)
            self.assertEqual(envelope["run"]["config"]["model"], "")
            self.assertEqual(envelope["run"]["progress"], {"done": 0, "total": 0})
            self.assertEqual(envelope["run"]["phaseHistory"], [])
            self.assertEqual(envelope["run"]["judge"], {"batches": 0, "failedBatches": 0, "costUSD": 0.0, "durationMs": 0, "lastError": None})

    def test_recovery_synthesizes_partial_apply_result_for_pre_persist_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            run_id = "clr_0123456789ab"
            run_dir = Path(directory) / run_id
            run_dir.mkdir()
            (run_dir / "run.json").write_text(json.dumps({
                "runId": run_id,
                "status": "applying",
                "phase": "applying",
                "config": {},
                "progress": {"done": 0, "total": 1},
                "phaseHistory": [{"phase": "applying", "startedAt": "2026-08-24T00:00:00Z", "finishedAt": None}],
            }))

            service = HerdrService(
                FakeClient([snapshot()]),
                environ={"HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory},
            )
            envelope = service.cleanup.get_run(run_id)

            self.assertEqual(envelope["run"]["status"], "failed")
            self.assertEqual(envelope["run"]["phase"], "failed")
            self.assertFalse(envelope["applyResult"]["complete"])
            self.assertEqual(envelope["applyResult"]["error"], "interrupted")
            self.assertEqual(envelope["applyResult"]["applied"], {"panes": [], "workspaces": []})

    def test_recovery_promotes_a_committed_apply_result_instead_of_corrupting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            run_id = "clr_0123456789ab"
            run_dir = Path(directory) / run_id
            run_dir.mkdir()
            (run_dir / "run.json").write_text(json.dumps({
                "runId": run_id,
                "status": "applying",
                "phase": "applying",
                "config": {},
                "progress": {"done": 0, "total": 1},
                "phaseHistory": [{"phase": "applying", "startedAt": "2026-08-24T00:00:00Z", "finishedAt": None}],
            }))
            committed = {
                "ok": True,
                "complete": True,
                "applied": {"panes": ["w1:p1"], "workspaces": []},
                "skipped": [],
                "piSessions": {"ended": 0, "failed": 0, "results": []},
                "ledger": {"path": "/tmp/ledger", "recordsAppended": 1, "eventsAppended": 2, "records": []},
                "deduplicatedPaneIds": [],
            }
            (run_dir / "apply.json").write_text(json.dumps(committed))

            service = HerdrService(
                FakeClient([snapshot()]),
                environ={"HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory},
            )
            envelope = service.cleanup.get_run(run_id)

            self.assertEqual(envelope["run"]["status"], "applied")
            self.assertEqual(envelope["run"]["phase"], "done")
            self.assertTrue(envelope["applyResult"]["complete"])
            self.assertEqual(envelope["applyResult"]["applied"]["panes"], ["w1:p1"])

    def test_async_apply_is_single_flight_and_blocks_a_new_cleanup_run(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap] * 16),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            wait_for_run(self, service.cleanup, run_id)
            deadline = time.monotonic() + 2
            while service.cleanup._active_run_id is not None and time.monotonic() < deadline:
                time.sleep(0.01)

            original_apply = service.cleanup.apply_run
            entered = threading.Event()
            release = threading.Event()
            calls = []

            def slow_apply(worker_run_id, pane_ids, workspace_ids):
                calls.append(worker_run_id)
                entered.set()
                if not release.wait(2):
                    raise RuntimeError("test apply release timed out")
                return original_apply(worker_run_id, pane_ids, workspace_ids)

            service.cleanup.apply_run = slow_apply
            first = service.cleanup.start_apply(run_id, ["w1:p1"], [])
            self.assertTrue(entered.wait(1))
            second = service.cleanup.start_apply(run_id, ["w1:p1"], [])
            self.assertEqual(first["status"], "applying")
            self.assertEqual(second["status"], "applying")
            self.assertEqual(calls, [run_id])
            with self.assertRaises(CleanupError) as busy:
                service.cleanup.start_run({})
            self.assertEqual(busy.exception.code, "cleanup_busy")

            release.set()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                envelope = service.cleanup.get_run(run_id)
                if envelope["run"]["status"] in {"applied", "failed"}:
                    break
                time.sleep(0.01)
            self.assertEqual(envelope["run"]["status"], "applied")
            self.assertTrue(envelope["applyResult"]["complete"])
            self.assertEqual(calls, [run_id])

    def test_async_apply_preserves_partial_result_after_unexpected_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot_with_panes([("w1:p1", 1, "done"), ("w1:p2", 1, "done")])
            service = HerdrService(
                FakeClient([snap] * 24),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            wait_for_run(self, service.cleanup, run_id)
            deadline = time.monotonic() + 2
            while service.cleanup._active_run_id is not None and time.monotonic() < deadline:
                time.sleep(0.01)
            invoke = service.invoke

            def crash_on_second_close(method, params):
                if method == "pane.close" and params["pane_id"] == "w1:p2":
                    raise SystemExit("simulated apply worker crash")
                result = invoke(method, params)
                if method == "pane.close" and params["pane_id"] == "w1:p1":
                    for item in [service.client.last, *service.client.snapshots]:
                        item["panes"] = [pane for pane in item["panes"] if pane["pane_id"] != "w1:p1"]
                        item["agents"] = [agent for agent in item.get("agents", []) if agent.get("pane_id") != "w1:p1"]
                return result

            service.invoke = crash_on_second_close
            service.cleanup.start_apply(run_id, ["w1:p1", "w1:p2"], [])
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                envelope = service.cleanup.get_run(run_id)
                if envelope["run"]["status"] == "failed":
                    break
                time.sleep(0.01)

            self.assertEqual(envelope["run"]["status"], "failed")
            partial = envelope["applyResult"]
            self.assertFalse(partial["ok"])
            self.assertFalse(partial["complete"])
            self.assertIn("simulated apply worker crash", partial["error"])
            self.assertEqual(partial["applied"]["panes"], ["w1:p1"])
            self.assertEqual(partial["skipped"], [])
            self.assertEqual(partial["ledger"]["recordsAppended"], 1)
            self.assertGreaterEqual(partial["ledger"]["eventsAppended"], 3)
            retry = service.cleanup.start_apply(run_id, ["w1:p1", "w1:p2"], [])
            self.assertEqual(retry["status"], "failed")

    def test_async_apply_preserves_committed_result_when_final_status_write_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap] * 16),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            wait_for_run(self, service.cleanup, run_id)
            deadline = time.monotonic() + 2
            while service.cleanup._active_run_id is not None and time.monotonic() < deadline:
                time.sleep(0.01)
            finish_phase = service.cleanup._finish_phase

            def fail_apply_finalization(worker_run_id, detail, **kwargs):
                if worker_run_id == run_id and detail.startswith("Closed "):
                    raise OSError("simulated final run status write failure")
                return finish_phase(worker_run_id, detail, **kwargs)

            service.cleanup._finish_phase = fail_apply_finalization
            service.cleanup.start_apply(run_id, ["w1:p1"], [])
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                envelope = service.cleanup.get_run(run_id)
                if envelope["run"]["status"] == "applied":
                    break
                time.sleep(0.01)

            self.assertEqual(envelope["run"]["status"], "applied")
            self.assertEqual(envelope["run"]["phase"], "done")
            self.assertIsNone(envelope["run"]["error"])
            self.assertTrue(envelope["applyResult"]["ok"])
            self.assertTrue(envelope["applyResult"]["complete"])
            self.assertEqual(envelope["applyResult"]["applied"]["panes"], ["w1:p1"])
            self.assertNotIn("simulated final run status write failure", json.dumps(envelope["applyResult"]))

    def test_bookkeeping_failure_after_native_close_does_not_reclassify_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap] * 16),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            wait_for_run(self, service.cleanup, run_id)
            deadline = time.monotonic() + 2
            while service.cleanup._active_run_id is not None and time.monotonic() < deadline:
                time.sleep(0.01)
            append = service.cleanup._append_ledger_records

            def fail_outcome_append(records):
                if records[0].get("recordType") == "outcome":
                    raise OSError("simulated ledger write failure")
                return append(records)

            service.cleanup._append_ledger_records = fail_outcome_append
            service.cleanup.start_apply(run_id, ["w1:p1"], [])
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                envelope = service.cleanup.get_run(run_id)
                if envelope["run"]["status"] == "failed":
                    break
                time.sleep(0.01)

            partial = envelope["applyResult"]
            self.assertEqual(envelope["run"]["status"], "failed")
            self.assertEqual(partial["applied"]["panes"], ["w1:p1"])
            self.assertEqual(partial["skipped"], [])
            self.assertIn(("pane.close", {"pane_id": "w1:p1"}), service.client.requests)
            events = [json.loads(line) for line in service.cleanup.ledger_path.read_text().splitlines()]
            self.assertEqual([event["recordType"] for event in events], ["association"])

    def test_unavailable_judge_still_produces_partial_report_and_path_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            client = FakeClient([snapshot(), snapshot()])
            service = HerdrService(
                client,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": "/does/not/exist",
                },
            )
            result = service.cleanup.start_run({"keepEvidence": True})
            run = wait_for_run(self, service.cleanup, result["runId"])
            self.assertEqual(run["run"]["status"], "partial")
            self.assertEqual(run["run"]["error"], "pi_unavailable")
            self.assertIsInstance(run["run"]["judge"]["lastError"], str)
            self.assertTrue(run["run"]["judge"]["lastError"])
            self.assertIn("spawn pi", run["run"]["judge"]["lastError"])
            evidence = Path(directory) / result["runId"] / "evidence" / "workspaces" / "w1" / "panes" / "w1%3Ap1" / "meta.json"
            self.assertTrue(evidence.is_file())
            with self.assertRaises(CleanupError) as context:
                service.cleanup.get_run("../../etc/passwd")
            self.assertEqual(context.exception.code, "not_found")

    def test_collector_records_revision_changes_after_dwell_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            first = snapshot_with_panes([("w1:p1", 1, "done"), ("w1:p2", 1, "done")])
            second = snapshot_with_panes([("w1:p1", 1, "done"), ("w1:p2", 2, "done")])
            service = HerdrService(
                FakeClient([first, second]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "valid",
                },
            )
            result = service.cleanup.start_run({"keepEvidence": True})
            run = wait_for_run(self, service.cleanup, result["runId"])
            self.assertEqual(run["run"]["status"], "done")
            self.assertIsNone(run["run"]["judge"]["lastError"])
            root = Path(directory) / result["runId"] / "evidence" / "workspaces" / "w1" / "panes"
            pane_a = json.loads((root / "w1%3Ap1" / "meta.json").read_text())
            pane_b = json.loads((root / "w1%3Ap2" / "meta.json").read_text())
            self.assertFalse(pane_a["revisionChanged"])
            self.assertTrue(pane_b["revisionChanged"])

    def test_collector_records_star_and_done_alert_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            client = FakeClient([snapshot(status="working"), snapshot(status="done"), snapshot(status="done")])
            stars = StarStore(store_path=None)
            alerts = AlertStore(store_path=None)
            service = HerdrService(
                client,
                stars=stars,
                alerts=alerts,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "valid",
                },
            )
            service.refresh_snapshot()
            service.refresh_snapshot()
            service.set_pane_star("w1:p1", True)

            result = service.cleanup.start_run({"keepEvidence": True})
            run = wait_for_run(self, service.cleanup, result["runId"])
            self.assertEqual(run["run"]["status"], "done")
            meta_path = Path(directory) / result["runId"] / "evidence" / "workspaces" / "w1" / "panes" / "w1%3Ap1" / "meta.json"
            meta = json.loads(meta_path.read_text())
            self.assertTrue(meta["starred"])
            self.assertGreaterEqual(meta["doneAlertAgeSeconds"], 0)
            self.assertLess(meta["doneAlertAgeSeconds"], 30)
            self.assertGreaterEqual(meta["unreadAlerts"], 1)

    def test_collector_serializes_integer_age_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            pi_session = Path(directory) / "pi-session.jsonl"
            pi_session.write_text(
                json.dumps({
                    "type": "message",
                    "message": {"role": "assistant", "usage": {"totalTokens": 3, "cost": {"total": 0.01}}},
                }) + "\n"
            )
            t = time.time()
            fractional_mtime = t - 0.3591364490986
            os.utime(pi_session, (fractional_mtime, fractional_mtime))

            def pi_snapshot(status):
                snap = snapshot(status=status)
                snap["panes"][0]["agent"] = "pi"
                return snap

            client = FakeClient([pi_snapshot("working"), pi_snapshot("done"), pi_snapshot("done")])
            alerts = AlertStore(store_path=None)
            service = HerdrService(
                client,
                alerts=alerts,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "valid",
                },
            )
            service.refresh_snapshot()
            service.refresh_snapshot()
            service.pi_semantic.journal.ingest(
                "w1:p1",
                {
                    "protocol": PI_SEMANTIC_PROTOCOL,
                    "pane_id": "w1:p1",
                    "kind": "snapshot",
                    "snapshot": {"session": {"file": str(pi_session)}, "entries": []},
                },
                namespace=service.pi_semantic.namespace,
            )

            result = service.cleanup.start_run({"keepEvidence": True})
            run = wait_for_run(self, service.cleanup, result["runId"])
            self.assertEqual(run["run"]["status"], "done")
            pane_root = Path(directory) / result["runId"] / "evidence" / "workspaces" / "w1" / "panes" / "w1%3Ap1"
            meta = json.loads((pane_root / "meta.json").read_text())
            report = json.loads((Path(directory) / result["runId"] / "report.json").read_text())
            signals = report["workspaces"][0]["panes"][0]["signals"]

            for key in ("doneAlertAgeSeconds", "blockedAlertAgeSeconds", "piStateAgeSeconds", "sessionFileAgeSeconds"):
                value = meta[key]
                self.assertTrue(value is None or (isinstance(value, int) and not isinstance(value, bool)))
            for key in ("doneAlertAgeSeconds", "sessionFileAgeSeconds"):
                value = signals[key]
                self.assertTrue(value is None or (isinstance(value, int) and not isinstance(value, bool)))

    def test_collector_reads_unread_alerts_beyond_response_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            alerts = AlertStore(store_path=None)
            alerts._alerts = [
                {
                    "id": "oldest-target",
                    "kind": "agent_blocked",
                    "paneId": "w1:p1",
                    "createdAt": "2020-01-01T00:00:00Z",
                    "isRead": False,
                }
            ] + [
                {
                    "id": f"newer-{index}",
                    "kind": "agent_done",
                    "paneId": f"other:{index}",
                    "createdAt": "2026-01-01T00:00:00Z",
                    "isRead": False,
                }
                for index in range(150)
            ]
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                alerts=alerts,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "valid",
                },
            )
            run_id = service.cleanup.start_run({"keepEvidence": True})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)
            pane = run["workspaces"][0]["panes"][0]
            meta = json.loads((Path(directory) / run_id / "evidence" / "workspaces" / "w1" / "panes" / "w1%3Ap1" / "meta.json").read_text())
            self.assertGreaterEqual(meta["unreadAlerts"], 1)
            self.assertFalse(pane["safeToClose"])
            self.assertIn("R5:unread_alerts", pane["blockedBy"])

    def test_cancelled_run_stays_failed_without_retry_or_report(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            counter_path = Path(directory) / "counter"
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "hang",
                    "FAKE_PI_COUNTER_FILE": str(counter_path),
                },
            )
            run_id = service.cleanup.start_run({})["runId"]
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if counter_path.exists() and service.cleanup.get_run(run_id)["run"]["phase"] == "judging":
                    break
                time.sleep(0.01)
            else:
                self.fail("judge did not start")
            cancelled = service.cleanup.cancel_run(run_id)
            self.assertEqual(cancelled["run"]["status"], "failed")
            self.assertEqual(cancelled["run"]["error"], "cancelled")
            final = wait_for_run(self, service.cleanup, run_id)
            self.assertEqual(service.cleanup.get_run(run_id)["run"]["status"], "failed")
            self.assertEqual(final["run"]["error"], "cancelled")
            self.assertEqual(counter_path.read_text(), "1")
            self.assertFalse((Path(directory) / run_id / "report.json").exists())
            self.assertFalse((Path(directory) / run_id / "evidence").exists())

    def test_collector_failure_removes_evidence_unless_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.refresh_snapshot()
            def fail_refresh():
                raise RuntimeError("dwell snapshot failed")
            service.refresh_snapshot = fail_refresh
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)
            self.assertEqual(run["run"]["status"], "failed")
            self.assertFalse((Path(directory) / run_id / "evidence").exists())

    def test_verbose_judge_text_is_bounded_in_report(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            service = HerdrService(
                FakeClient([snapshot(), snapshot()]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "verbose",
                },
            )
            run_id = service.cleanup.start_run({})["runId"]
            wait_for_run(self, service.cleanup, run_id)
            report = json.loads((Path(directory) / run_id / "report.json").read_text())
            pane = report["workspaces"][0]["panes"][0]
            self.assertLessEqual(len(pane["reason"]), 281)
            self.assertLessEqual(len(pane["evidenceCited"]), 8)
            self.assertTrue(all(len(item) <= 121 for item in pane["evidenceCited"]))

    def test_report_preserves_titles_judge_summaries_evidence_and_usage_insights(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            snap["panes"][0].update({"title": None, "label": "Useful pane title"})
            service = HerdrService(
                FakeClient([snap, snap]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "valid",
                },
            )
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)

            workspace = run["workspaces"][0]
            pane = workspace["panes"][0]
            summary = run["summary"]
            self.assertEqual(workspace["title"], "One")
            self.assertEqual(workspace["workspaceReason"], "All reviewed panes are complete and quiet.")
            self.assertIn("completed cleanup-test work", workspace["summary"])
            self.assertEqual(pane["title"], "Useful pane title")
            self.assertIn("completed its assigned cleanup-test task", pane["summary"])
            self.assertEqual(pane["evidenceCited"], ["tail.txt"])
            self.assertIn("Output stayed unchanged", pane["activitySummary"])
            self.assertEqual(pane["usageSummary"], "No Pi session was detected.")
            self.assertEqual(summary["workspaceTitles"], ["One"])
            self.assertEqual(summary["workspacesScanned"], 1)
            self.assertEqual(summary["classifications"]["completed"], 1)
            self.assertEqual(summary["workspaceSummaries"][0]["title"], "One")
            judge_phase = next(item for item in run["run"]["phaseHistory"] if item["phase"] == "judging")
            self.assertIn("One", judge_phase["detail"])

    def test_judge_summary_counts_distinct_workspaces_with_duplicate_titles(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            snap["workspaces"].append({"workspace_id": "w2", "label": "One", "focused": False})
            snap["tabs"].append({"tab_id": "w2:t1", "workspace_id": "w2", "label": "One"})
            snap["panes"].append({
                "pane_id": "w2:p1",
                "workspace_id": "w2",
                "tab_id": "w2:t1",
                "agent_status": "done",
                "revision": 1,
                "focused": False,
                "title": "w2:p1",
            })
            service = HerdrService(
                FakeClient([snap, snap]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}

            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)

            judge_phase = next(item for item in run["run"]["phaseHistory"] if item["phase"] == "judging")
            self.assertIn("across 2 workspaces: One, One", judge_phase["detail"])
            self.assertEqual(run["summary"]["workspacesScanned"], 2)
            self.assertEqual(run["summary"]["workspaceTitles"], ["One", "One"])

    def test_apply_ends_active_pi_before_pane_close_and_persists_ledger(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertLess(methods.index("pane.send_input"), methods.index("pane.close"))
            send = next(params for method, params in service.client.requests[before:] if method == "pane.send_input")
            self.assertEqual(send, {"pane_id": "w1:p1", "text": "/quit", "keys": ["enter"]})
            self.assertEqual(applied["applied"]["panes"], ["w1:p1"])
            self.assertEqual(applied["piSessions"]["ended"], 1)
            self.assertEqual(applied["piSessions"]["failed"], 0)
            self.assertEqual(applied["ledger"]["recordsAppended"], 1)
            self.assertEqual(applied["ledger"]["eventsAppended"], 2)
            ledger_path = Path(applied["ledger"]["path"])
            self.assertTrue(ledger_path.is_file())
            self.assertEqual(os.stat(ledger_path).st_mode & 0o777, 0o600)
            self.assertNotIn(str(service.cleanup._run_dir(run_id)), str(ledger_path))
            events = [json.loads(line) for line in ledger_path.read_text().splitlines()]
            self.assertEqual([event["recordType"] for event in events], ["association", "outcome"])
            self.assertEqual(events[0]["recordId"], events[1]["recordId"])
            self.assertEqual(events[0]["close"]["outcome"], "pending")
            self.assertTrue(events[0]["piSession"]["active"])
            persisted = events[1]
            self.assertEqual(persisted["workspace"], {"id": "w1", "title": "One"})
            self.assertEqual(persisted["pane"]["id"], "w1:p1")
            self.assertEqual(persisted["piSession"]["sessionId"], "pi-session-1")
            self.assertEqual(persisted["piSession"]["sessionName"], "Cleanup 1")
            self.assertEqual(persisted["piSession"]["totalTokens"], 100)
            self.assertEqual(persisted["quit"]["outcome"], "ended")
            self.assertIsNone(persisted["quit"]["error"])
            self.assertEqual(persisted["close"]["outcome"], "closed")
            newer = service.cleanup.runs_root / "clr_ffffffffffff"
            newer.mkdir()
            (newer / "run.json").write_text(json.dumps({"startedAt": "9999-01-01T00:00:00Z"}))
            service.cleanup._prune()
            self.assertTrue(ledger_path.is_file())

    def test_ledger_preserves_association_if_apply_crashes_before_close_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            invoke = service.invoke

            def crash_before_close(method, params):
                if method == "pane.close":
                    raise SystemExit("simulated process crash")
                return invoke(method, params)

            service.invoke = crash_before_close
            with self.assertRaisesRegex(SystemExit, "simulated process crash"):
                service.cleanup.apply_run(run_id, ["w1:p1"], [])

            events = [json.loads(line) for line in service.cleanup.ledger_path.read_text().splitlines()]
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["recordType"], "association")
            self.assertEqual(events[0]["close"]["outcome"], "pending")
            self.assertEqual(events[0]["pane"]["id"], "w1:p1")
            self.assertEqual(events[0]["piSession"]["sessionId"], "pi-session-1")

    def test_apply_skips_close_when_active_pi_does_not_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, disconnect_on_quit=False)
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["applied"]["panes"], [])
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "pi_quit_failed"}])
            self.assertEqual(applied["piSessions"]["failed"], 1)
            self.assertEqual(applied["piSessions"]["results"][0]["reason"], "pi_still_active")
            self.assertEqual(applied["ledger"]["records"][0]["quit"]["error"], "pi_still_active")
            self.assertEqual(applied["ledger"]["records"][0]["close"]["outcome"], "skipped")

    def test_apply_skips_replacement_pi_session_without_sending_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            replacement_file = Path(directory) / "replacement.jsonl"
            replacement_file.write_text("")
            service.pi_semantic.journal.ingest(
                "w1:p1",
                {
                    "protocol": dict(PI_SEMANTIC_PROTOCOL),
                    "pane_id": "w1:p1",
                    "instance_id": "bridge-1",
                    "sequence": 2,
                    "kind": "snapshot",
                    "generated_at": "2026-08-24T00:01:00Z",
                    "session_id": "replacement-session",
                    "snapshot": {
                        "session": {"id": "replacement-session", "file": str(replacement_file)},
                        "state": {"idle": True},
                        "entries": [],
                    },
                },
                namespace=service.pi_semantic.namespace,
            )
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertNotIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            self.assertEqual(applied["ledger"]["records"][0]["piSession"]["sessionId"], "replacement-session")

    def test_apply_fails_closed_when_report_active_pi_bridge_disconnects(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            service.pi_semantic.journal.mark_connected(
                "w1:p1",
                False,
                namespace=service.pi_semantic.namespace,
            )
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertNotIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            self.assertEqual(applied["ledger"]["records"][0]["piSession"]["connected"], False)

    def test_apply_fails_closed_when_active_pi_capability_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            fresh = service.workspaces_response()
            for workspace in fresh["workspaces"]:
                for pane in workspace["panes"]:
                    pane.pop("pi_semantic", None)
            service.refresh_snapshot = lambda **_kwargs: {}
            service.workspaces_response = lambda: copy.deepcopy(fresh)
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertNotIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            association = applied["ledger"]["records"][0]["piSession"]
            self.assertTrue(association["active"])
            self.assertIsNone(association["connected"])

    def test_apply_rechecks_explicit_pane_after_pi_quit_before_close(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            original_hook = service.client.request_hook

            def focus_after_quit(method, params):
                original_hook(method, params)
                if method == "pane.send_input":
                    for item in [service.client.last, *service.client.snapshots]:
                        for pane in item["panes"]:
                            if pane["pane_id"] == params["pane_id"]:
                                pane["focused"] = True

            service.client.request_hook = focus_after_quit
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            self.assertEqual(applied["piSessions"]["ended"], 1)
            self.assertEqual(applied["ledger"]["records"][0]["close"]["outcome"], "skipped")

    def test_apply_does_not_close_if_same_pi_session_reconnects_idle_after_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory)
            original_hook = service.client.request_hook
            original_refresh = service.refresh_snapshot
            sent_quit = False
            post_quit_refreshes = 0

            def observe_quit(method, params):
                nonlocal sent_quit
                original_hook(method, params)
                if method == "pane.send_input":
                    sent_quit = True

            def reconnect_before_close(**kwargs):
                nonlocal post_quit_refreshes
                value = original_refresh(**kwargs)
                if sent_quit:
                    post_quit_refreshes += 1
                    if post_quit_refreshes == 2:
                        service.pi_semantic.journal.mark_connected(
                            "w1:p1",
                            True,
                            namespace=service.pi_semantic.namespace,
                        )
                return value

            service.client.request_hook = observe_quit
            service.refresh_snapshot = reconnect_before_close
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertIn("pane.send_input", methods)
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            self.assertEqual(applied["piSessions"]["ended"], 0)
            self.assertEqual(applied["piSessions"]["failed"], 1)
            result = applied["piSessions"]["results"][0]
            self.assertFalse(result["quitSucceeded"])
            self.assertEqual(result["reason"], "pi_reconnected_after_quit")
            ledger = applied["ledger"]["records"][0]
            self.assertEqual(ledger["piSession"]["active"], True)
            self.assertEqual(ledger["quit"]["outcome"], "failed")
            self.assertEqual(ledger["quit"]["error"], "pi_reconnected_after_quit")

    def test_workspace_apply_rejects_pane_moved_in_from_another_report_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, mode="workspace")
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            report_path = service.cleanup._run_dir(run_id) / "report.json"
            report = json.loads(report_path.read_text())
            workspace = report["workspaces"][0]
            workspace.update({"workspaceCloseRecommended": True, "workspaceSafeToClose": True, "workspaceBlockedBy": [], "git": {"state": "clean"}})
            other = copy.deepcopy(workspace)
            other.update({"workspaceId": "w2", "title": "Two", "workspaceSafeToClose": False})
            other["panes"][0].update({"paneId": "w2:p2", "title": "Moved pane"})
            report["workspaces"].append(other)
            report_path.write_text(json.dumps(report))

            fresh = service.workspaces_response()
            moved = copy.deepcopy(fresh["workspaces"][0]["panes"][0])
            moved.update({"pane_id": "w2:p2", "workspace_id": "w1", "title": "Moved pane"})
            fresh["workspaces"][0]["panes"].append(moved)
            service.refresh_snapshot = lambda **_kwargs: {}
            service.workspaces_response = lambda: copy.deepcopy(fresh)
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, [], ["w1"])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertNotIn("pane.send_input", methods)
            self.assertNotIn("workspace.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1", "reason": "R8:state_changed"}])

    def test_workspace_apply_rechecks_later_pane_while_earlier_pi_is_ending(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, pane_ids=("w1:p1", "w1:p2"), mode="workspace")
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            report_path = service.cleanup._run_dir(run_id) / "report.json"
            report = json.loads(report_path.read_text())
            report["workspaces"][0].update({"workspaceCloseRecommended": True, "workspaceSafeToClose": True, "workspaceBlockedBy": [], "git": {"state": "clean"}})
            report_path.write_text(json.dumps(report))
            original_hook = service.client.request_hook

            def start_later_pane(method, params):
                original_hook(method, params)
                if method == "pane.send_input" and params["pane_id"] == "w1:p1":
                    for item in [service.client.last, *service.client.snapshots]:
                        for pane in item["panes"]:
                            if pane["pane_id"] == "w1:p2":
                                pane["agent_status"] = "working"

            service.client.request_hook = start_later_pane
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, [], ["w1"])

            requests = service.client.requests[before:]
            sends = [params["pane_id"] for method, params in requests if method == "pane.send_input"]
            self.assertEqual(sends, ["w1:p1"])
            self.assertNotIn("workspace.close", [method for method, _ in requests])
            self.assertEqual(applied["skipped"], [{"id": "w1", "reason": "R8:state_changed"}])
            self.assertEqual(applied["piSessions"]["ended"], 1)

    def test_workspace_apply_records_fresh_association_when_ended_pi_reconnects(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, pane_ids=("w1:p1", "w1:p2"), mode="workspace")
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            report_path = service.cleanup._run_dir(run_id) / "report.json"
            report = json.loads(report_path.read_text())
            report["workspaces"][0].update({"workspaceCloseRecommended": True, "workspaceSafeToClose": True, "workspaceBlockedBy": [], "git": {"state": "clean"}})
            report_path.write_text(json.dumps(report))
            original_hook = service.client.request_hook
            original_refresh = service.refresh_snapshot
            first_quit_sent = False
            post_quit_refreshes = 0

            def observe_first_quit(method, params):
                nonlocal first_quit_sent
                original_hook(method, params)
                if method == "pane.send_input" and params["pane_id"] == "w1:p1":
                    first_quit_sent = True

            def reconnect_before_second_pane(**kwargs):
                nonlocal post_quit_refreshes
                value = original_refresh(**kwargs)
                if first_quit_sent:
                    post_quit_refreshes += 1
                    if post_quit_refreshes == 2:
                        service.pi_semantic.journal.mark_connected(
                            "w1:p1",
                            True,
                            namespace=service.pi_semantic.namespace,
                        )
                return value

            service.client.request_hook = observe_first_quit
            service.refresh_snapshot = reconnect_before_second_pane
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, [], ["w1"])

            requests = service.client.requests[before:]
            self.assertEqual(
                [params["pane_id"] for method, params in requests if method == "pane.send_input"],
                ["w1:p1"],
            )
            self.assertNotIn("workspace.close", [method for method, _ in requests])
            self.assertEqual(applied["piSessions"]["ended"], 0)
            self.assertEqual(applied["piSessions"]["failed"], 1)
            pane_one = next(item for item in applied["ledger"]["records"] if item["pane"]["id"] == "w1:p1")
            self.assertTrue(pane_one["piSession"]["active"])
            self.assertEqual(pane_one["quit"]["outcome"], "failed")
            self.assertEqual(pane_one["quit"]["error"], "pi_reconnected_after_quit")

    def test_workspace_apply_runs_final_safety_check_after_pi_quit(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, mode="workspace")
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            report_path = service.cleanup._run_dir(run_id) / "report.json"
            report = json.loads(report_path.read_text())
            report["workspaces"][0].update({"workspaceCloseRecommended": True, "workspaceSafeToClose": True, "workspaceBlockedBy": [], "git": {"state": "clean"}})
            report_path.write_text(json.dumps(report))
            original_hook = service.client.request_hook

            def focus_after_quit(method, params):
                original_hook(method, params)
                if method == "pane.send_input":
                    for item in [service.client.last, *service.client.snapshots]:
                        item["focused_workspace_id"] = "w1"
                        item["workspaces"][0]["focused"] = True

            service.client.request_hook = focus_after_quit
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, [], ["w1"])

            methods = [method for method, _ in service.client.requests[before:]]
            self.assertIn("pane.send_input", methods)
            self.assertNotIn("workspace.close", methods)
            self.assertEqual(applied["skipped"], [{"id": "w1", "reason": "R8:state_changed"}])

    def test_workspace_apply_ends_implicit_pi_panes_and_deduplicates_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            service, run_id = self._pi_cleanup_run(directory, pane_ids=("w1:p1", "w1:p2"), mode="workspace")
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            report_path = service.cleanup._run_dir(run_id) / "report.json"
            report = json.loads(report_path.read_text())
            report["workspaces"][0].update({"workspaceCloseRecommended": True, "workspaceSafeToClose": True, "workspaceBlockedBy": [], "git": {"state": "clean"}})
            report_path.write_text(json.dumps(report))
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], ["w1"])

            requests = service.client.requests[before:]
            methods = [method for method, _ in requests]
            send_indexes = [index for index, method in enumerate(methods) if method == "pane.send_input"]
            self.assertEqual(len(send_indexes), 2)
            self.assertTrue(all(index < methods.index("workspace.close") for index in send_indexes))
            self.assertNotIn("pane.close", methods)
            self.assertEqual(applied["applied"]["workspaces"], ["w1"])
            self.assertEqual(applied["deduplicatedPaneIds"], ["w1:p1"])
            self.assertEqual(applied["piSessions"]["ended"], 2)
            self.assertEqual(applied["ledger"]["recordsAppended"], 2)
            self.assertEqual(applied["ledger"]["eventsAppended"], 4)
            self.assertEqual({record["pane"]["id"] for record in applied["ledger"]["records"]}, {"w1:p1", "w1:p2"})
            self.assertTrue(all(record["close"]["scope"] == "workspace" for record in applied["ledger"]["records"]))

    def test_workspace_recommendation_aggregates_every_judge_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            counter = Path(directory) / "counter"
            snap = snapshot_with_panes([(f"w1:p{index}", 1, "done") for index in range(1, 10)])
            service = HerdrService(
                FakeClient([snap, snap]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "workspace_mixed",
                    "FAKE_PI_COUNTER_FILE": str(counter),
                },
            )
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)

            self.assertEqual(run["run"]["judge"]["batches"], 2)
            self.assertFalse(run["workspaces"][0]["workspaceCloseRecommended"])
            self.assertIn("completed cleanup-test work", run["workspaces"][0]["summary"])

    def test_workspace_recommendation_cannot_override_a_child_keep_decision(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap, snap]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                    "FAKE_PI_MODE": "workspace_child_keep",
                },
            )
            service.workspace_git_status = lambda _workspace_id: {
                "staged": False,
                "unstaged": False,
                "untracked": False,
            }

            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)

            workspace = run["workspaces"][0]
            self.assertTrue(workspace["workspaceCloseRecommended"])
            self.assertFalse(workspace["panes"][0]["safeToClose"])
            self.assertFalse(workspace["workspaceSafeToClose"])
            self.assertIn("R6:pane_blocked", workspace["workspaceBlockedBy"])

    def test_report_blocks_dirty_workspace_final_pane_from_default_close(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap, snap]),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {
                "staged": False,
                "unstaged": True,
                "untracked": False,
            }

            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)

            workspace = run["workspaces"][0]
            pane = workspace["panes"][0]
            self.assertTrue(pane["closeRecommended"])
            self.assertFalse(pane["safeToClose"])
            self.assertIn("R6:git_dirty", pane["blockedBy"])
            self.assertFalse(workspace["workspaceSafeToClose"])

    def test_apply_rechecks_git_before_closing_a_workspace_final_pane(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot()
            service = HerdrService(
                FakeClient([snap] * 12),
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {
                "staged": False,
                "unstaged": False,
                "untracked": False,
            }
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)
            self.assertTrue(run["workspaces"][0]["panes"][0]["safeToClose"])
            service.workspace_git_status = lambda _workspace_id: {
                "staged": True,
                "unstaged": False,
                "untracked": False,
            }
            before = len(service.client.requests)

            applied = service.cleanup.apply_run(run_id, ["w1:p1"], [])

            self.assertEqual(applied["applied"]["panes"], [])
            self.assertEqual(applied["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
            self.assertNotIn("pane.close", [method for method, _ in service.client.requests[before:]])

    def test_apply_can_close_two_approved_explicit_panes_in_one_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot_with_panes([("w1:p1", 1, "done"), ("w1:p2", 1, "done")])

            def remove_closed_pane(method, params):
                if method != "pane.close":
                    return
                pane_id = params["pane_id"]
                for item in [client.last, *client.snapshots]:
                    item["panes"] = [pane for pane in item["panes"] if pane["pane_id"] != pane_id]
                    item["agents"] = [agent for agent in item.get("agents", []) if agent.get("pane_id") != pane_id]

            client = FakeClient([snap] * 16, request_hook=remove_closed_pane)
            service = HerdrService(
                client,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": False, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)
            self.assertTrue(all(pane["safeToClose"] for pane in run["workspaces"][0]["panes"]))

            applied = service.cleanup.apply_run(run_id, ["w1:p1", "w1:p2"], [])

            self.assertEqual(applied["applied"]["panes"], ["w1:p1", "w1:p2"])
            self.assertEqual(applied["skipped"], [])
            closes = [params["pane_id"] for method, params in client.requests if method == "pane.close"]
            self.assertEqual(closes, ["w1:p1", "w1:p2"])

    def test_apply_keeps_final_pane_when_multi_pane_workspace_git_is_dirty(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_pi = write_fake_pi(directory)
            snap = snapshot_with_panes([("w1:p1", 1, "done"), ("w1:p2", 1, "done")])

            def remove_closed_pane(method, params):
                if method != "pane.close":
                    return
                pane_id = params["pane_id"]
                for item in [client.last, *client.snapshots]:
                    item["panes"] = [pane for pane in item["panes"] if pane["pane_id"] != pane_id]

            client = FakeClient([snap] * 16, request_hook=remove_closed_pane)
            service = HerdrService(
                client,
                environ={
                    "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
                    "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                    "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
                },
            )
            service.workspace_git_status = lambda _workspace_id: {"staged": False, "unstaged": True, "untracked": False}
            run_id = service.cleanup.start_run({})["runId"]
            run = wait_for_run(self, service.cleanup, run_id)
            self.assertTrue(all(pane["safeToClose"] for pane in run["workspaces"][0]["panes"]))

            applied = service.cleanup.apply_run(run_id, ["w1:p1", "w1:p2"], [])

            self.assertEqual(applied["applied"]["panes"], ["w1:p1"])
            self.assertEqual(applied["skipped"], [{"id": "w1:p2", "reason": "R8:state_changed"}])
            closes = [params["pane_id"] for method, params in client.requests if method == "pane.close"]
            self.assertEqual(closes, ["w1:p1"])


class CleanupJudgeTests(unittest.TestCase):
    def _manager_with_batch(self, directory, mode, *, counter_path=None, model=None, judge_charter=None, extra_environ=None):
        fake_pi = write_fake_pi(directory)
        environ = {
            "HERDR_HARNESS_CLEANUP_RUNS_ROOT": directory,
            "HERDR_HARNESS_CLEANUP_PI_BIN": str(fake_pi),
            "FAKE_PI_MODE": mode,
            "FAKE_PI_ARGV_FILE": str(Path(directory) / "argv.jsonl"),
        }
        if counter_path is not None:
            environ["FAKE_PI_COUNTER_FILE"] = str(counter_path)
        if extra_environ is not None:
            environ.update(extra_environ)
        service = HerdrService(FakeClient([snapshot()]), environ=environ)
        manager = service.cleanup
        run_id = "clr_0123456789ab"
        run_dir = manager._run_dir(run_id)
        (run_dir / "judge" / "sessions").mkdir(parents=True)
        (run_dir / "evidence").mkdir()
        config = {"model": model, "thinkingLevel": "medium"}
        if judge_charter is not None:
            config["judgeCharter"] = judge_charter
        (run_dir / "run.json").write_text(json.dumps({"config": config}))
        workspace = {"workspace_id": "w1", "label": "One"}
        entries = [{"workspace": workspace, "pane": {}, "meta": {"paneId": "w1:p1"}, "base": run_dir / "evidence"}]
        return manager, run_id, workspace, entries, Path(environ["FAKE_PI_ARGV_FILE"])

    def test_judge_returns_valid_verdict_from_fake_pi(self):
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(directory, "valid")
            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertFalse(result["judgeFailed"])
            verdict = result["panes"]["w1:p1"]
            self.assertEqual(verdict["classification"], "completed")
            self.assertTrue(verdict["closeRecommended"])
            self.assertAlmostEqual(verdict["confidence"], 0.95)
            self.assertIn("completed its assigned cleanup-test task", verdict["summary"])
            self.assertEqual(verdict["_workspaceReason"], "All reviewed panes are complete and quiet.")
            self.assertAlmostEqual(result["costUSD"], 0.00165)

    def test_judge_child_path_prepends_pi_bin_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            path_file = Path(directory) / "path.txt"
            sentinel_path = os.pathsep.join(["/usr/bin", "/bin"])
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(
                directory,
                "valid",
                extra_environ={
                    "FAKE_PI_PATH_FILE": str(path_file),
                    "PATH": sentinel_path,
                },
            )

            manager._run_judge_batch(run_id, 1, workspace, entries)

            captured_path = path_file.read_text().split(os.pathsep)
            self.assertEqual(os.path.realpath(captured_path[0]), os.path.realpath(directory))
            self.assertIn("/usr/bin", captured_path)
            self.assertIn("/bin", captured_path)

    def test_judge_passes_model_only_when_explicitly_configured(self):
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, argv_path = self._manager_with_batch(directory, "valid")

            manager._run_judge_batch(run_id, 1, workspace, entries)

            argv = json.loads(argv_path.read_text().splitlines()[0])
            self.assertNotIn("--model", argv)
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, argv_path = self._manager_with_batch(
                directory,
                "valid",
                model="provider/model",
            )

            manager._run_judge_batch(run_id, 1, workspace, entries)

            argv = json.loads(argv_path.read_text().splitlines()[0])
            self.assertIn("--model", argv)
            self.assertEqual(argv[argv.index("--model") + 1], "provider/model")

    def test_judge_uses_custom_charter_when_configured(self):
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, argv_path = self._manager_with_batch(
                directory,
                "valid",
                judge_charter="CUSTOM JUDGE TEXT",
            )

            manager._run_judge_batch(run_id, 1, workspace, entries)

            argv = json.loads(argv_path.read_text().splitlines()[0])
            charter = argv[argv.index("--append-system-prompt") + 1]
            self.assertIn("CUSTOM JUDGE TEXT", charter)
            self.assertNotIn("workspace-hygiene judge", charter)

    def test_judge_surfaces_stderr_when_output_is_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(directory, "stderr_invalid")

            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertTrue(result["judgeFailed"])
            self.assertIn("No API key found for fireworks.", result["lastError"])
            raw = (manager._run_dir(run_id) / "judge" / "batch-1.jsonl").read_text()
            self.assertIn("---stderr---", raw)
            self.assertIn("No API key found for fireworks.", raw)

    def test_judge_retries_malformed_output_and_keeps_both_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            counter_path = Path(directory) / "counter"
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(
                directory,
                "retry",
                counter_path=counter_path,
            )
            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertFalse(result["judgeFailed"])
            self.assertEqual(result["panes"]["w1:p1"]["classification"], "completed")
            raw = (manager._run_dir(run_id) / "judge" / "batch-1.jsonl").read_text()
            self.assertIn("not json at all", raw)
            self.assertIn("```json", raw)
            self.assertEqual(counter_path.read_text(), "2")

    def test_judge_timeout_kills_hanging_process_without_close_recommendation(self):
        with tempfile.TemporaryDirectory() as directory:
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(directory, "hang")
            started = time.monotonic()
            result = manager._run_judge_batch(run_id, 1, workspace, entries, timeout=1)
            elapsed = time.monotonic() - started

            self.assertLess(elapsed, 5)
            self.assertTrue(result["judgeFailed"])
            verdict = result["panes"]["w1:p1"]
            self.assertEqual(verdict["classification"], "unknown")
            self.assertFalse(verdict["closeRecommended"])

    def test_judge_prompt_states_required_schema_and_retry_diagnosis(self):
        with tempfile.TemporaryDirectory() as directory:
            counter_path = Path(directory) / "counter"
            manager, run_id, workspace, entries, argv_path = self._manager_with_batch(
                directory,
                "retry",
                counter_path=counter_path,
            )

            manager._run_judge_batch(run_id, 1, workspace, entries)

            invocations = [json.loads(line) for line in argv_path.read_text().splitlines()]
            self.assertEqual(len(invocations), 2)
            first_prompt = invocations[0][-1]
            second_prompt = invocations[1][-1]
            self.assertIn("w1:p1", first_prompt)
            self.assertNotIn("w3:p1", first_prompt)
            for key in (
                "paneId",
                "classification",
                "closeRecommended",
                "confidence",
                "summary",
                "evidenceCited",
                "workspaceCloseRecommended",
                "workspaceReason",
                "needs_human",
            ):
                self.assertIn(key, first_prompt)
                self.assertIn(key, second_prompt)
            self.assertNotEqual(first_prompt, second_prompt)
            self.assertGreater(len(second_prompt), len(first_prompt))
            self.assertIn("failed validation", second_prompt)
            self.assertIn("no parseable JSON object", second_prompt)

    def test_judge_succeeds_on_retry_after_wrong_schema_response(self):
        with tempfile.TemporaryDirectory() as directory:
            counter_path = Path(directory) / "counter"
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(
                directory,
                "schema_retry",
                counter_path=counter_path,
            )

            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertFalse(result["judgeFailed"])
            verdict = result["panes"]["w1:p1"]
            self.assertEqual(verdict["classification"], "completed")
            self.assertTrue(verdict["closeRecommended"])
            self.assertEqual(counter_path.read_text(), "2")

    def test_judge_retries_missing_pane_id_and_uses_real_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            counter_path = Path(directory) / "counter"
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(
                directory,
                "wrong_pane_retry",
                counter_path=counter_path,
            )

            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertFalse(result["judgeFailed"])
            self.assertEqual(counter_path.read_text(), "2")
            self.assertEqual(result["panes"]["w1:p1"]["classification"], "completed")
            self.assertEqual(result["panes"]["w1:p1"]["reason"], "finished")

    def test_judge_matches_percent_encoded_pane_id_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            counter_path = Path(directory) / "counter"
            manager, run_id, workspace, entries, _argv_path = self._manager_with_batch(
                directory,
                "percent_encoded",
                counter_path=counter_path,
            )

            result = manager._run_judge_batch(run_id, 1, workspace, entries)

            self.assertFalse(result["judgeFailed"])
            self.assertEqual(counter_path.read_text(), "1")
            self.assertEqual(result["panes"]["w1:p1"]["classification"], "completed")


class CleanupHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.runs_root = Path(self.tempdir.name) / "runs"
        self.fake_pi = write_fake_pi(self.tempdir.name)
        self.client = FakeClient([snapshot(), snapshot(), snapshot()])
        self.service = HerdrService(
            self.client,
            environ={
                "HERDR_HARNESS_CLEANUP_RUNS_ROOT": str(self.runs_root),
                "HERDR_HARNESS_CLEANUP_DWELL_SECONDS": "0",
                "HERDR_HARNESS_CLEANUP_PI_BIN": str(self.fake_pi),
                "FAKE_PI_MODE": "valid",
            },
        )
        self.service.workspace_git_status = lambda _workspace_id: {
            "staged": False,
            "unstaged": False,
            "untracked": False,
        }
        self.server = make_server(self.service, host="127.0.0.1", port=0, api_token="test-secret")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)

    def request(self, path, *, method="GET", payload=None, token="test-secret"):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, method=method, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, response.headers, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, error.headers, json.loads(error.read())

    def wait_for_run(self, run_id, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, _, body = self.request(f"/api/v1/cleanup/runs/{run_id}")
            self.assertEqual(status, 200)
            if body["run"]["status"] in {"done", "partial", "failed", "applied"}:
                return body
            time.sleep(0.01)
        self.fail(f"cleanup run {run_id} did not finish within {timeout} seconds")

    def start_run(self):
        status, _, body = self.request("/api/v1/cleanup/runs", method="POST", payload={"keepEvidence": True})
        self.assertEqual(status, 202)
        return body["runId"]

    def test_cleanup_run_requires_bearer_token(self):
        status, _, body = self.request(
            "/api/v1/cleanup/runs",
            method="POST",
            payload={},
            token=None,
        )
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

    def test_second_cleanup_run_returns_cleanup_busy(self):
        self.service.cleanup.environ["FAKE_PI_MODE"] = "slow"
        run_id = self.start_run()
        status, _, body = self.request("/api/v1/cleanup/runs", method="POST", payload={})
        self.assertEqual(status, 409)
        self.assertEqual(body["error"]["code"], "cleanup_busy")
        self.wait_for_run(run_id)

    def test_cleanup_get_and_list_use_run_envelopes(self):
        self.service.cleanup.environ["FAKE_PI_MODE"] = "slow"
        run_id = self.start_run()
        status, _, active = self.request(f"/api/v1/cleanup/runs/{run_id}")
        self.assertEqual(status, 200)
        self.assertNotIn("status", active)
        self.assertIn("run", active)
        self.assertIsInstance(active["run"]["phaseHistory"], list)
        finished = self.wait_for_run(run_id)
        self.assertEqual(finished["run"]["phase"], "done")
        self.assertEqual(finished["run"]["progress"]["done"], finished["run"]["progress"]["total"])
        self.assertIn("phaseDetail", finished["run"])
        self.assertIn("progress", finished["run"])
        self.assertIsInstance(finished["run"]["phaseHistory"], list)
        self.assertIn("judge", finished["run"])
        self.assertIn("workspaces", finished)
        self.assertIn("summary", finished)
        status, _, listed = self.request("/api/v1/cleanup/runs")
        self.assertEqual(status, 200)
        self.assertEqual(listed["runs"][0]["runId"], run_id)
        self.assertNotIn("run", listed["runs"][0])
        self.assertNotIn("workspaces", listed["runs"][0])

    def test_nonexistent_well_formed_cleanup_run_is_not_found(self):
        status, _, body = self.request("/api/v1/cleanup/runs/clr_deadbeef0000")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")

    def test_malformed_cleanup_run_path_cannot_escape_runs_root(self):
        status, _, body = self.request("/api/v1/cleanup/runs/%2e%2e%2f%2e%2e%2fetc")
        self.assertEqual(status, 404)
        self.assertEqual(body["error"]["code"], "not_found")
        self.assertEqual(os.listdir(self.runs_root), [])

    def test_apply_skips_a_pane_that_became_working(self):
        run_id = self.start_run()
        run = self.wait_for_run(run_id)
        pane = run["workspaces"][0]["panes"][0]
        self.assertTrue(pane["safeToClose"])

        self.client.snapshots = [snapshot(status="working")]
        status, _, body = self.request(
            f"/api/v1/cleanup/runs/{run_id}/apply",
            method="POST",
            payload={"paneIds": ["w1:p1"], "workspaceIds": []},
        )
        self.assertEqual(status, 202)
        self.assertEqual(body["runId"], run_id)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status, _, finished = self.request(f"/api/v1/cleanup/runs/{run_id}")
            self.assertEqual(status, 200)
            if finished["run"]["status"] in {"applied", "failed"}:
                break
            time.sleep(0.01)
        else:
            self.fail("cleanup apply did not finish")
        self.assertEqual(finished["run"]["status"], "applied")
        self.assertTrue(finished["applyResult"]["complete"])
        self.assertEqual(finished["applyResult"]["applied"]["panes"], [])
        self.assertEqual(finished["applyResult"]["skipped"], [{"id": "w1:p1", "reason": "R8:state_changed"}])
        self.assertNotIn(("pane.close", {"pane_id": "w1:p1"}), self.client.requests)


if __name__ == "__main__":
    unittest.main()
