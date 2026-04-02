import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import objectives
from cmux_harness.orchestrator import Orchestrator


class TestOrchestrator(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.engine = object()
        self.orchestrator = Orchestrator(self.engine)

    def test_append_message_persists_and_preserves_order(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        first = self.orchestrator._append_message(objective["id"], "system", "hello")
        second = self.orchestrator._append_message(
            objective["id"], "progress", "world", metadata={"task_id": "task-1"}
        )

        self.assertIn("id", first)
        self.assertIn("timestamp", first)
        self.assertEqual(first["type"], "system")
        self.assertEqual(first["content"], "hello")
        self.assertEqual(first["metadata"], {})
        self.assertEqual(second["metadata"], {"task_id": "task-1"})

        on_disk = (self.objectives_dir / objective["id"] / "messages.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(on_disk), 2)
        parsed = [json.loads(line) for line in on_disk]
        self.assertEqual([msg["content"] for msg in parsed], ["hello", "world"])
        self.assertEqual(self.orchestrator.get_messages(objective["id"]), parsed)

    def test_load_messages_handles_valid_missing_and_malformed_lines(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        messages_path = self.objectives_dir / objective["id"] / "messages.jsonl"
        messages_path.write_text(
            "\n".join(
                [
                    json.dumps({"id": "1", "timestamp": "2026-04-02T10:00:00+00:00", "type": "system", "content": "a", "metadata": {}}),
                    "{not json}",
                    json.dumps({"id": "2", "timestamp": "2026-04-02T10:01:00+00:00", "type": "system", "content": "b", "metadata": {}}),
                ]
            ),
            encoding="utf-8",
        )

        loaded = self.orchestrator._load_messages(objective["id"])

        self.assertEqual([msg["id"] for msg in loaded], ["1", "2"])
        self.assertEqual(self.orchestrator._load_messages("missing-objective"), [])

    def test_get_messages_returns_all_filters_and_loads_on_cold_start(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        messages_path = self.objectives_dir / objective["id"] / "messages.jsonl"
        messages = [
            {"id": "1", "timestamp": "2026-04-02T10:00:00+00:00", "type": "system", "content": "a", "metadata": {}},
            {"id": "2", "timestamp": "2026-04-02T10:05:00+00:00", "type": "progress", "content": "b", "metadata": {}},
            {"id": "3", "timestamp": "2026-04-02T10:10:00+00:00", "type": "system", "content": "c", "metadata": {}},
        ]
        messages_path.write_text("\n".join(json.dumps(msg) for msg in messages) + "\n", encoding="utf-8")

        cold_orchestrator = Orchestrator(self.engine)

        self.assertEqual(cold_orchestrator.get_messages(objective["id"]), messages)
        self.assertEqual(
            [msg["id"] for msg in cold_orchestrator.get_messages(objective["id"], after="2026-04-02T10:04:59+00:00")],
            ["2", "3"],
        )

    def test_start_objective_validates_and_sets_active_state(self):
        valid = objectives.create_objective("Ship feature", "/tmp/project")
        missing_goal = objectives.create_objective("placeholder", "/tmp/project")
        objectives.update_objective(missing_goal["id"], {"goal": ""})

        self.assertTrue(self.orchestrator.start_objective(valid["id"]))
        self.assertEqual(self.orchestrator.get_active_objective_id(), valid["id"])

        updated = objectives.read_objective(valid["id"])
        self.assertEqual(updated["status"], "planning")
        messages = self.orchestrator.get_messages(valid["id"])
        self.assertEqual(messages[-1]["type"], "system")
        self.assertIn("Starting objective: Ship feature", messages[-1]["content"])

        self.assertFalse(self.orchestrator.start_objective("does-not-exist"))
        self.assertFalse(self.orchestrator.start_objective(missing_goal["id"]))
        another = objectives.create_objective("Another", "/tmp/project")
        self.assertFalse(self.orchestrator.start_objective(another["id"]))

    def test_get_active_objective_id_defaults_to_none(self):
        self.assertIsNone(self.orchestrator.get_active_objective_id())
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        self.orchestrator.start_objective(objective["id"])
        self.assertEqual(self.orchestrator.get_active_objective_id(), objective["id"])

    def test_is_orchestrated_workspace_checks_active_objective_tasks(self):
        self.assertFalse(self.orchestrator.is_orchestrated_workspace("ws-1"))

        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "tasks": [
                    {"id": "task-1", "workspaceId": "ws-123"},
                    {"id": "task-2", "workspaceId": None},
                ]
            },
        )
        self.orchestrator.start_objective(objective["id"])

        self.assertFalse(self.orchestrator.is_orchestrated_workspace("ws-999"))
        self.assertTrue(self.orchestrator.is_orchestrated_workspace("ws-123"))

    def test_stop_objective_clears_active_and_appends_message(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        self.orchestrator.start_objective(objective["id"])

        self.assertFalse(self.orchestrator.stop_objective("wrong-id"))
        self.assertTrue(self.orchestrator.stop_objective(objective["id"]))
        self.assertIsNone(self.orchestrator.get_active_objective_id())
        self.assertEqual(self.orchestrator.get_messages(objective["id"])[-1]["content"], "Objective stopped.")


if __name__ == "__main__":
    unittest.main()
