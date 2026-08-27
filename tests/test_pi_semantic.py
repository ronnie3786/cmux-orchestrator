import json
import os
import socket
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Optional

from herdr_harness.pi_semantic import (
    PI_SEMANTIC_PROTOCOL,
    PiSemanticError,
    PiSemanticJournal,
    PiSemanticManager,
    ensure_private_socket_directory,
    pi_semantic_socket_path,
)


def pi_snapshot(pane_id="w1:p1"):
    return {
        "panes": [
            {
                "pane_id": pane_id,
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "agent": "pi",
            }
        ],
        "agents": [{"pane_id": pane_id, "agent": "pi"}],
    }


def bridge_record(pane_id, kind, *, sequence=0, **values):
    return {
        "protocol": dict(PI_SEMANTIC_PROTOCOL),
        "pane_id": pane_id,
        "instance_id": "bridge-one",
        "sequence": sequence,
        "kind": kind,
        "generated_at": "2026-08-12T00:00:00Z",
        **values,
    }


class FakeExtensionSocket:
    def __init__(
        self,
        path,
        pane_id,
        hello_capabilities: Optional[dict] = None,
        command_failures: Optional[dict[str, str]] = None,
    ):
        self.path = path
        self.pane_id = pane_id
        self.hello_capabilities = hello_capabilities
        self.command_failures = command_failures
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        Path(path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.server.bind(path)
        os.chmod(path, 0o600)
        self.server.listen(8)
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.commands = []

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.stop_event.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as wake:
                wake.connect(self.path)
        except OSError:
            pass
        self.thread.join(timeout=1)
        self.server.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass

    def _run(self):
        while not self.stop_event.is_set():
            connection, _ = self.server.accept()
            threading.Thread(target=self._handle, args=(connection,), daemon=True).start()

    def _handle(self, connection):
        with connection:
            reader = connection.makefile("rb")
            line = reader.readline()
            if not line:
                return
            request = json.loads(line)
            if request["type"] == "subscribe":
                hello_values = {"session_id": "session-1"}
                if self.hello_capabilities is not None:
                    hello_values["capabilities"] = self.hello_capabilities
                connection.sendall(
                    json.dumps(
                        bridge_record(
                            self.pane_id,
                            "hello",
                            **hello_values,
                        )
                    ).encode()
                    + b"\n"
                )
                connection.sendall(
                    json.dumps(
                        bridge_record(
                            self.pane_id,
                            "snapshot",
                            session_id="session-1",
                            snapshot={
                                "session": {"id": "session-1", "future": "kept"},
                                "state": {"idle": True, "future": {"kept": True}},
                                "entries": [
                                    {
                                        "type": "message",
                                        "id": "entry-1",
                                        "parentId": None,
                                        "timestamp": "2026-08-12T00:00:00Z",
                                        "message": {"role": "user", "content": "hello"},
                                        "futureEntryField": 7,
                                    }
                                ],
                                "pending_interactions": [],
                                "futureSnapshotField": {"yes": 1},
                            },
                        )
                    ).encode()
                    + b"\n"
                )
                while not self.stop_event.wait(0.05):
                    pass
                return
            if request["type"] == "command":
                self.commands.append(request)
                failure_code = self.command_failures.get(request["command"]) if self.command_failures else None
                if failure_code:
                    connection.sendall(
                        json.dumps(
                            {
                                "protocol": PI_SEMANTIC_PROTOCOL,
                                "pane_id": self.pane_id,
                                "type": "response",
                                "request_id": request["id"],
                                "success": False,
                                "error": {
                                    "code": failure_code,
                                    "message": f"{request['command']} rejected for the test",
                                },
                            }
                        ).encode()
                        + b"\n"
                    )
                    return
                connection.sendall(
                    json.dumps(
                        {
                            "protocol": PI_SEMANTIC_PROTOCOL,
                            "pane_id": self.pane_id,
                            "type": "response",
                            "request_id": request["id"],
                            "success": True,
                            "result": {"accepted": True, "future": "kept"},
                        }
                    ).encode()
                    + b"\n"
                )


class PiSemanticTests(unittest.TestCase):
    def test_socket_path_is_pane_specific_deterministic_and_bounded(self):
        first = pi_semantic_socket_path("/tmp/herdr.sock", "w1:p1")
        second = pi_semantic_socket_path("/tmp/herdr.sock", "w1:p2")
        fallback = pi_semantic_socket_path("/" + "very-long/" * 20 + "herdr.sock", "w1:p1")

        self.assertNotEqual(first, second)
        self.assertEqual(first, pi_semantic_socket_path("/tmp/herdr.sock", "w1:p1"))
        self.assertLessEqual(len(os.fsencode(fallback)), 100)
        self.assertIn(f"herdr-pi-{os.getuid()}", fallback)

    def test_socket_directory_is_private_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            arbitrary = Path(temporary) / "bridge"
            arbitrary.mkdir(mode=0o755)
            os.chmod(arbitrary, 0o755)
            with self.assertRaisesRegex(Exception, "not bridge-owned"):
                ensure_private_socket_directory(str(arbitrary / "pane.sock"))
            self.assertEqual(stat.S_IMODE(arbitrary.stat().st_mode), 0o755)

        parent = Path(f"/tmp/herdr-pi-{os.getuid()}")
        existed = parent.exists()
        original_mode = stat.S_IMODE(parent.stat().st_mode) if existed else None
        try:
            parent.mkdir(mode=0o700, exist_ok=True)
            os.chmod(parent, 0o777)
            ensure_private_socket_directory(str(parent / "pane.sock"))
            self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
        finally:
            if original_mode is not None:
                os.chmod(parent, original_mode)
            elif not any(parent.iterdir()):
                parent.rmdir()

        link = Path(f"/tmp/hp-{os.getuid()}")
        if not os.path.lexists(link):
            with tempfile.TemporaryDirectory() as temporary:
                link.symlink_to(temporary, target_is_directory=True)
                try:
                    with self.assertRaisesRegex(Exception, "unsafe"):
                        ensure_private_socket_directory(str(link / "pane.sock"))
                finally:
                    link.unlink()

    def test_journal_preserves_unknown_fields_deduplicates_and_persists(self):
        with tempfile.TemporaryDirectory() as temporary:
            os.chmod(temporary, 0o755)
            path = str(Path(temporary) / "semantic.sqlite3")
            journal = PiSemanticJournal(path, maximum_events_per_pane=64)
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "snapshot",
                    snapshot={
                        "session": {"id": "session-1"},
                        "state": {"idle": False, "cost": {"totalUSD": 1.25, "totalTokens": 4200}},
                        "entries": [{"id": "entry-1", "parentId": None, "future": [1, 2]}],
                        "pending_interactions": [],
                        "futureSnapshot": {"kept": True},
                        "usage": {"costUSD": 1.25, "totalTokens": 4200},
                    },
                ),
            )
            event = bridge_record(
                "w1:p1",
                "event",
                sequence=1,
                session_id="session-1",
                event={
                    "type": "message_start",
                    "message": {"role": "assistant"},
                    "future": 9,
                    "cost": {"totalUSD": 1.25},
                },
            )
            self.assertEqual(len(journal.ingest("w1:p1", event)), 1)
            self.assertEqual(journal.ingest("w1:p1", event), [])
            journal.close()

            reopened = PiSemanticJournal(path, maximum_events_per_pane=64)
            snapshot = reopened.snapshot("w1:p1")
            values = reopened.events_after("w1:p1", 0)
            self.assertEqual(snapshot["entries"][0]["id"], "entry-1")
            self.assertEqual(snapshot["entries"][0]["parentId"], None)
            self.assertTrue(snapshot["futureSnapshot"]["kept"])
            self.assertEqual(snapshot["state"]["cost"], {"totalUSD": 1.25, "totalTokens": 4200})
            self.assertEqual(snapshot["usage"], {"costUSD": 1.25, "totalTokens": 4200})
            self.assertEqual(values[0]["event"]["future"], 9)
            self.assertEqual(values[0]["event"]["cost"], {"totalUSD": 1.25})
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            for suffix in ("-wal", "-shm"):
                companion = f"{path}{suffix}"
                if os.path.exists(companion):
                    self.assertEqual(stat.S_IMODE(os.stat(companion).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(temporary).st_mode), 0o755)
            reopened.close()

    def test_journal_rejects_a_symlink_database_without_following_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "target.sqlite3"
            target.touch(mode=0o600)
            link = Path(temporary) / "semantic.sqlite3"
            link.symlink_to(target)
            with self.assertRaisesRegex(Exception, "unsafe"):
                PiSemanticJournal(str(link))

    def test_current_snapshot_and_cursor_survive_harness_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "semantic.sqlite3")
            journal = PiSemanticJournal(path, maximum_events_per_pane=64)
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "snapshot",
                    snapshot={"session": {"id": "session-1"}, "entries": [{"id": "entry-1"}]},
                ),
            )
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "event",
                    sequence=1,
                    session_id="session-1",
                    event={"type": "message_end", "message": {"role": "assistant"}},
                ),
            )
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "snapshot",
                    sequence=1,
                    session_id="session-1",
                    snapshot={
                        "session": {"id": "session-1"},
                        "entries": [{"id": "entry-1"}, {"id": "entry-2", "parentId": "entry-1"}],
                    },
                ),
            )
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "event",
                    sequence=2,
                    session_id="session-1",
                    event={"type": "turn_start", "turnIndex": 2},
                ),
            )
            before = journal.snapshot("w1:p1")
            journal.close()

            reopened = PiSemanticJournal(path, maximum_events_per_pane=64)
            after = reopened.snapshot("w1:p1")
            self.assertEqual([entry["id"] for entry in before["entries"]], ["entry-1", "entry-2"])
            self.assertEqual(after["entries"], before["entries"])
            self.assertEqual(after["cursor"], before["cursor"])
            self.assertGreater(after["cursor"], 0)
            self.assertGreater(after["latest_cursor"], after["cursor"])
            self.assertEqual(
                [item["event"]["type"] for item in reopened.events_after("w1:p1", after["cursor"])],
                ["turn_start"],
            )
            reopened.close()

    def test_shared_database_isolates_same_pane_across_herdr_sockets(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "semantic.sqlite3")
            environment = {"HERDR_HARNESS_PI_STORE_PATH": path}
            first = PiSemanticManager(str(Path(temporary) / "one.sock"), environ=environment)
            second = PiSemanticManager(str(Path(temporary) / "two.sock"), environ=environment)
            first.sync_snapshot(pi_snapshot())
            second.sync_snapshot(pi_snapshot())
            first.journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "snapshot",
                    snapshot={"session": {"id": "one"}, "entries": [{"id": "only-one"}]},
                ),
                namespace=first.namespace,
            )
            second.journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "snapshot",
                    snapshot={"session": {"id": "two"}, "entries": [{"id": "only-two"}]},
                ),
                namespace=second.namespace,
            )

            self.assertEqual(first.snapshot_response("w1:p1")["entries"][0]["id"], "only-one")
            self.assertEqual(second.snapshot_response("w1:p1")["entries"][0]["id"], "only-two")
            first.close()
            second.close()

    def test_trim_retains_a_contiguous_newest_suffix_within_byte_bound(self):
        journal = PiSemanticJournal(":memory:", maximum_events_per_pane=64, maximum_bytes_per_pane=1024 * 1024)
        payloads = ["a", "b", "x" * 400_000, "y" * 400_000, "z" * 400_000]
        for sequence, payload in enumerate(payloads, start=1):
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "event",
                    sequence=sequence,
                    event={"type": f"event-{sequence}", "payload": payload},
                ),
            )
        retained = journal.events_after("w1:p1", 0)
        cursors = [item["cursor"] for item in retained]
        self.assertEqual(cursors, list(range(cursors[0], cursors[-1] + 1)))
        self.assertEqual([item["event"]["type"] for item in retained], ["event-4", "event-5"])
        journal.close()

    def test_active_turn_retention_never_makes_snapshot_cursor_unreplayable(self):
        journal = PiSemanticJournal(":memory:", maximum_events_per_pane=64)
        journal.ingest(
            "w1:p1",
            bridge_record(
                "w1:p1",
                "snapshot",
                snapshot={"session": {"id": "session-1"}, "entries": [{"id": "entry-1"}]},
            ),
        )
        for sequence in range(1, 81):
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1",
                    "event",
                    sequence=sequence,
                    event={
                        "type": "message_update",
                        "assistantMessageEvent": {
                            "type": "text_delta",
                            "contentIndex": 0,
                            "delta": "x",
                        },
                    },
                ),
            )

        snapshot = journal.snapshot("w1:p1")
        oldest, latest = journal.bounds("w1:p1")
        replay = journal.events_after("w1:p1", snapshot["cursor"], limit=128)
        self.assertLessEqual(oldest - 1, snapshot["cursor"])
        self.assertEqual(len(replay), 80)
        self.assertEqual(replay[-1]["cursor"], latest)

        journal.ingest(
            "w1:p1",
            bridge_record(
                "w1:p1",
                "snapshot",
                sequence=80,
                snapshot={
                    "session": {"id": "session-1"},
                    "entries": [{"id": "entry-1"}, {"id": "entry-2"}],
                },
            ),
        )
        oldest_after, latest_after = journal.bounds("w1:p1")
        self.assertEqual(latest_after - oldest_after + 1, 64)
        self.assertEqual(journal.snapshot("w1:p1")["cursor"], latest_after)
        journal.close()

    def test_pinned_checkpoint_rechecks_retention_on_tick_not_every_ingest(self):
        journal = PiSemanticJournal(":memory:", maximum_events_per_pane=64)
        journal.ingest(
            "w1:p1",
            bridge_record(
                "w1:p1", "snapshot", snapshot={"session": {"id": "session-1"}, "entries": []},
            ),
        )
        total_ingests = 200
        for sequence in range(1, total_ingests + 1):
            journal.ingest(
                "w1:p1",
                bridge_record(
                    "w1:p1", "event", sequence=sequence,
                    event={"type": "message_update", "text": str(sequence)},
                ),
            )

        self.assertLessEqual(journal._trim_scan_count, total_ingests // 64 + 2)
        journal.close()

    def test_hello_does_not_skip_unread_replay_sequences(self):
        journal = PiSemanticJournal(":memory:")
        journal.ingest("w1:p1", bridge_record("w1:p1", "hello", sequence=100))
        self.assertEqual(journal.source_position("w1:p1"), ("bridge-one", 0))
        journal.ingest(
            "w1:p1",
            bridge_record("w1:p1", "event", sequence=1, event={"type": "turn_start"}),
        )
        journal.ingest("w1:p1", bridge_record("w1:p1", "hello", sequence=100))
        self.assertEqual(journal.source_position("w1:p1"), ("bridge-one", 1))
        journal.close()

    def test_connection_events_emit_once_per_transition_and_offline_history_is_available(self):
        journal = PiSemanticJournal(":memory:")
        manager = PiSemanticManager(
            "/tmp/nonexistent-herdr.sock",
            environ={},
            journal=journal,
        )
        journal.ingest(
            "w1:p1",
            bridge_record(
                "w1:p1",
                "snapshot",
                snapshot={"session": {"id": "session-1"}, "entries": [{"id": "entry-1"}]},
            ),
            namespace=manager.namespace,
        )
        journal.mark_connected("w1:p1", False, namespace=manager.namespace)
        first = journal.mark_connected("w1:p1", True, namespace=manager.namespace)
        duplicate = journal.mark_connected("w1:p1", True, namespace=manager.namespace)
        disconnected = journal.mark_connected("w1:p1", False, namespace=manager.namespace)
        self.assertEqual(first["event"], {"type": "bridge.connection", "connected": True})
        self.assertIsNone(duplicate)
        self.assertEqual(disconnected["event"], {"type": "bridge.connection", "connected": False})

        manager.sync_snapshot(pi_snapshot())
        capability = manager.capability("w1:p1")
        self.assertTrue(capability["available"])
        self.assertFalse(capability["connected"])
        self.assertTrue(capability["capabilities"]["listModels"])
        self.assertTrue(capability["capabilities"]["setModel"])
        self.assertTrue(capability["capabilities"]["compact"])
        manager.close()

    def test_explicit_empty_environment_uses_an_in_memory_store(self):
        manager = PiSemanticManager("/tmp/herdr.sock", environ={})
        self.assertEqual(manager.journal.path, ":memory:")
        manager.close()

    def test_manager_connects_to_safe_socket_and_forwards_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            herdr_path = str(Path(temporary) / "herdr.sock")
            pane_id = "w1:p1"
            path = pi_semantic_socket_path(herdr_path, pane_id)
            extension = FakeExtensionSocket(path, pane_id).start()
            self.addCleanup(extension.stop)
            manager = PiSemanticManager(
                herdr_path,
                environ={},
                journal=PiSemanticJournal(":memory:"),
            )
            manager.sync_snapshot(pi_snapshot(pane_id))
            manager.start()
            self.addCleanup(manager.close)

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if manager.snapshot_response(pane_id)["entries"]:
                    break
                time.sleep(0.02)
            snapshot = manager.snapshot_response(pane_id)
            response = manager.command(pane_id, "prompt", {"text": "Fix it"})

            self.assertTrue(snapshot["available"])
            self.assertTrue(snapshot["connected"])
            self.assertEqual(snapshot["entries"][0]["id"], "entry-1")
            self.assertEqual(snapshot["futureSnapshotField"], {"yes": 1})
            self.assertTrue(response["success"])
            self.assertEqual(extension.commands[-1]["command"], "prompt")
            self.assertEqual(extension.commands[-1]["payload"], {"text": "Fix it"})

    def test_manager_uses_observed_hello_capabilities_for_model_commands(self):
        cases = [
            (
                {
                    "prompt": True,
                    "steer": True,
                    "followUp": True,
                    "abort": True,
                    "interactionResponse": False,
                },
                False,
            ),
            (
                {
                    "prompt": True,
                    "steer": True,
                    "followUp": True,
                    "abort": True,
                    "interactionResponse": False,
                    "listModels": True,
                    "setModel": True,
                },
                True,
            ),
        ]
        for hello_capabilities, models_supported in cases:
            with self.subTest(models_supported=models_supported), tempfile.TemporaryDirectory() as temporary:
                herdr_path = str(Path(temporary) / "herdr.sock")
                pane_id = "w1:p1"
                path = pi_semantic_socket_path(herdr_path, pane_id)
                extension = FakeExtensionSocket(
                    path,
                    pane_id,
                    hello_capabilities=hello_capabilities,
                ).start()
                self.addCleanup(extension.stop)
                manager = PiSemanticManager(
                    herdr_path,
                    environ={},
                    journal=PiSemanticJournal(":memory:"),
                )
                manager.sync_snapshot(pi_snapshot(pane_id))
                manager.start()
                self.addCleanup(manager.close)

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if manager.capability(pane_id)["connected"]:
                        break
                    time.sleep(0.02)
                capability = manager.capability(pane_id)["capabilities"]

                self.assertTrue(capability["prompt"])
                self.assertIs(capability["listModels"], models_supported)
                self.assertIs(capability["setModel"], models_supported)

    def test_manager_reports_thinking_level_capability_from_observed_hello(self):
        cases = [
            (
                {
                    "prompt": True,
                    "steer": True,
                    "followUp": True,
                    "abort": True,
                    "interactionResponse": False,
                },
                False,
            ),
            (
                {
                    "prompt": True,
                    "steer": True,
                    "followUp": True,
                    "abort": True,
                    "interactionResponse": False,
                    "setThinkingLevel": True,
                },
                True,
            ),
        ]
        for hello_capabilities, thinking_level_supported in cases:
            with self.subTest(thinking_level_supported=thinking_level_supported), tempfile.TemporaryDirectory() as temporary:
                herdr_path = str(Path(temporary) / "herdr.sock")
                pane_id = "w1:p1"
                path = pi_semantic_socket_path(herdr_path, pane_id)
                extension = FakeExtensionSocket(
                    path,
                    pane_id,
                    hello_capabilities=hello_capabilities,
                ).start()
                self.addCleanup(extension.stop)
                manager = PiSemanticManager(
                    herdr_path,
                    environ={},
                    journal=PiSemanticJournal(":memory:"),
                )
                manager.sync_snapshot(pi_snapshot(pane_id))
                manager.start()
                self.addCleanup(manager.close)

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if manager.capability(pane_id)["connected"]:
                        break
                    time.sleep(0.02)
                capability = manager.capability(pane_id)["capabilities"]

                self.assertTrue(capability["prompt"])
                self.assertIs(capability["setThinkingLevel"], thinking_level_supported)

    def test_manager_maps_bridge_errors_for_model_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            herdr_path = str(Path(temporary) / "herdr.sock")
            pane_id = "w1:p1"
            path = pi_semantic_socket_path(herdr_path, pane_id)
            extension = FakeExtensionSocket(
                path,
                pane_id,
                command_failures={"list_models": "unsupported", "set_model": "command_rejected"},
            ).start()
            self.addCleanup(extension.stop)
            manager = PiSemanticManager(
                herdr_path,
                environ={},
                journal=PiSemanticJournal(":memory:"),
            )
            manager.sync_snapshot(pi_snapshot(pane_id))
            manager.start()
            self.addCleanup(manager.close)

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if manager.snapshot_response(pane_id)["entries"]:
                    break
                time.sleep(0.02)

            with self.assertRaises(PiSemanticError) as unsupported:
                manager.command(pane_id, "list_models", {})
            self.assertEqual(unsupported.exception.status, 501)

            with self.assertRaises(PiSemanticError) as rejected:
                manager.command(pane_id, "set_model", {"provider": "x", "id": "y"})
            self.assertEqual(rejected.exception.status, 409)

    def test_manager_maps_bridge_errors_for_thinking_level_commands(self):
        cases = [("unsupported", 501), ("command_rejected", 409)]
        for failure, expected_status in cases:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                herdr_path = str(Path(temporary) / "herdr.sock")
                pane_id = "w1:p1"
                path = pi_semantic_socket_path(herdr_path, pane_id)
                extension = FakeExtensionSocket(
                    path,
                    pane_id,
                    command_failures={"set_thinking_level": failure},
                ).start()
                self.addCleanup(extension.stop)
                manager = PiSemanticManager(
                    herdr_path,
                    environ={},
                    journal=PiSemanticJournal(":memory:"),
                )
                manager.sync_snapshot(pi_snapshot(pane_id))
                manager.start()
                self.addCleanup(manager.close)

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if manager.snapshot_response(pane_id)["entries"]:
                        break
                    time.sleep(0.02)

                with self.assertRaises(PiSemanticError) as error:
                    manager.command(pane_id, "set_thinking_level", {"level": "high"})
                self.assertEqual(error.exception.status, expected_status)


if __name__ == "__main__":
    unittest.main()
