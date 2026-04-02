import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import objectives


class TestObjectives(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)

    def test_create_objective_creates_directory_and_json(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project", base_branch="develop")

        objective_dir = self.objectives_dir / objective["id"]
        self.assertTrue(objective_dir.is_dir())
        self.assertEqual(objective["goal"], "Ship feature")
        self.assertEqual(objective["projectDir"], "/tmp/project")
        self.assertEqual(objective["baseBranch"], "develop")
        self.assertEqual(objective["status"], "planning")
        self.assertEqual(objective["tasks"], [])

        on_disk = json.loads((objective_dir / "objective.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["id"], objective["id"])

    def test_read_objective_returns_data(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        loaded = objectives.read_objective(objective["id"])

        self.assertEqual(loaded["id"], objective["id"])
        self.assertEqual(loaded["goal"], "Ship feature")

    def test_update_objective_merges_updates(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        original_updated_at = objective["updatedAt"]

        updated = objectives.update_objective(objective["id"], {"status": "executing", "tasks": [{"id": "task-1"}]})

        self.assertEqual(updated["status"], "executing")
        self.assertEqual(updated["tasks"], [{"id": "task-1"}])
        self.assertNotEqual(updated["updatedAt"], original_updated_at)
        self.assertEqual(updated["goal"], "Ship feature")

    def test_list_objectives_returns_all(self):
        first = objectives.create_objective("First", "/tmp/one")
        second = objectives.create_objective("Second", "/tmp/two")

        listed = objectives.list_objectives()

        self.assertEqual({item["id"] for item in listed}, {first["id"], second["id"]})

    def test_create_task_dir_creates_expected_files(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        task_dir = objectives.create_task_dir(objective["id"], "task-1")

        self.assertTrue(task_dir.is_dir())
        self.assertEqual((task_dir / "spec.md").read_text(encoding="utf-8"), "")
        self.assertEqual((task_dir / "context.md").read_text(encoding="utf-8"), "")
        self.assertEqual((task_dir / "progress.md").read_text(encoding="utf-8"), "")

    def test_read_and_write_task_file(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.create_task_dir(objective["id"], "task-1")

        objectives.write_task_file(objective["id"], "task-1", "result.md", "done")
        content = objectives.read_task_file(objective["id"], "task-1", "result.md")

        self.assertEqual(content, "done")
        self.assertIsNone(objectives.read_task_file(objective["id"], "task-1", "missing.md"))


if __name__ == "__main__":
    unittest.main()
