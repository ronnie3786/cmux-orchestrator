import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import objectives
from cmux_harness import planner


def _valid_parsed_plan():
    return {
        "tasks": [
            {
                "id": "task-1",
                "title": "Fix token expiry check",
                "files": ["TokenManager.swift", "TokenStorage.swift"],
                "dependsOn": [],
                "checkpoints": ["Read current implementation", "Implement fix", "Run tests"],
            },
            {
                "id": "task-2",
                "title": "Add regression tests",
                "files": ["TokenManagerTests.swift"],
                "dependsOn": ["task-1"],
                "checkpoints": ["Review changes", "Add tests"],
            },
        ]
    }


class TestValidatePlan(unittest.TestCase):

    def test_valid_plan_passes_validation(self):
        is_valid, error = planner.validate_plan(_valid_parsed_plan())

        self.assertTrue(is_valid)
        self.assertEqual(error, "")

    def test_missing_tasks_key_fails(self):
        is_valid, error = planner.validate_plan({})

        self.assertFalse(is_valid)
        self.assertIn('missing "tasks"', error)

    def test_empty_tasks_list_fails(self):
        is_valid, error = planner.validate_plan({"tasks": []})

        self.assertFalse(is_valid)
        self.assertIn("must not be empty", error)

    def test_task_missing_required_fields_fails(self):
        parsed = {"tasks": [{"id": "task-1", "title": "Only title"}]}

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("missing required fields", error)

    def test_duplicate_task_ids_fail(self):
        parsed = {
            "tasks": [
                {
                    "id": "task-1",
                    "title": "First",
                    "files": ["a.py"],
                    "dependsOn": [],
                    "checkpoints": ["Do it"],
                },
                {
                    "id": "task-1",
                    "title": "Second",
                    "files": ["b.py"],
                    "dependsOn": [],
                    "checkpoints": ["Do it"],
                },
            ]
        }

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("duplicate task id", error)

    def test_invalid_dependency_reference_fails(self):
        parsed = _valid_parsed_plan()
        parsed["tasks"][1]["dependsOn"] = ["task-9"]

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("invalid dependency", error)

    def test_circular_dependency_fails(self):
        parsed = {
            "tasks": [
                {
                    "id": "task-a",
                    "title": "A",
                    "files": ["a.py"],
                    "dependsOn": ["task-b"],
                    "checkpoints": ["Do A"],
                },
                {
                    "id": "task-b",
                    "title": "B",
                    "files": ["b.py"],
                    "dependsOn": ["task-a"],
                    "checkpoints": ["Do B"],
                },
            ]
        }

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("circular dependency", error)

    def test_too_many_checkpoints_fails(self):
        parsed = _valid_parsed_plan()
        parsed["tasks"][0]["checkpoints"] = ["1", "2", "3", "4", "5", "6"]

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("no more than 5", error)

    def test_zero_checkpoints_fails(self):
        parsed = _valid_parsed_plan()
        parsed["tasks"][0]["checkpoints"] = []

        is_valid, error = planner.validate_plan(parsed)

        self.assertFalse(is_valid)
        self.assertIn("at least 1 checkpoint", error)


class TestParsePlan(unittest.TestCase):

    @patch("cmux_harness.planner.run_sonnet")
    @patch("cmux_harness.planner.run_haiku")
    def test_parse_plan_succeeds_on_first_sonnet_attempt(self, mock_haiku, mock_sonnet):
        mock_sonnet.return_value = _valid_parsed_plan()

        result = planner.parse_plan("raw plan")

        self.assertEqual(result, _valid_parsed_plan())
        mock_sonnet.assert_called_once()
        mock_haiku.assert_not_called()

    @patch("cmux_harness.planner.run_sonnet")
    @patch("cmux_harness.planner.run_haiku")
    def test_parse_plan_succeeds_on_first_haiku_fallback(self, mock_haiku, mock_sonnet):
        mock_sonnet.return_value = "not json"
        mock_haiku.side_effect = [_valid_parsed_plan()]

        result = planner.parse_plan("raw plan")

        self.assertEqual(result, _valid_parsed_plan())
        mock_sonnet.assert_called_once()
        self.assertEqual(mock_haiku.call_count, 1)

    @patch("cmux_harness.planner.run_sonnet")
    @patch("cmux_harness.planner.run_haiku")
    def test_parse_plan_sonnet_first_then_haiku(self, mock_haiku, mock_sonnet):
        mock_sonnet.return_value = "not json"
        mock_haiku.side_effect = [_valid_parsed_plan(), {"tasks": []}]

        result = planner.parse_plan("raw plan")

        self.assertEqual(result, _valid_parsed_plan())
        mock_sonnet.assert_called_once()
        self.assertEqual(mock_haiku.call_count, 1)

    @patch("cmux_harness.planner.run_sonnet")
    @patch("cmux_harness.planner.run_haiku")
    def test_parse_plan_returns_error_after_all_failures(self, mock_haiku, mock_sonnet):
        mock_sonnet.return_value = "still bad"
        mock_haiku.side_effect = ["not json", {"tasks": []}]

        result = planner.parse_plan("raw plan")

        self.assertEqual(result, {"error": "parse_failed", "raw_plan": "raw plan"})


class TestBuildPlanningPrompt(unittest.TestCase):

    def test_build_planning_prompt_contains_goal_plan_file_and_format(self):
        prompt = planner.build_planning_prompt("Ship planner pipeline")

        self.assertIn("Ship planner pipeline", prompt)
        self.assertIn("./plan.md", prompt)
        self.assertIn("## Task N: [title]", prompt)
        self.assertIn("- Depends on:", prompt)


class TestPlanToTasks(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)

    def test_plan_to_tasks_converts_plan_and_writes_specs(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        parsed = _valid_parsed_plan()

        tasks = planner.plan_to_tasks(parsed, objective["id"])

        self.assertEqual(len(tasks), 2)
        self.assertEqual(tasks[0]["id"], "task-1")
        self.assertEqual(tasks[0]["status"], "queued")
        self.assertEqual(tasks[0]["dependsOn"], [])
        self.assertIsNone(tasks[0]["workspaceId"])
        self.assertEqual(
            tasks[0]["checkpoints"],
            [
                {"name": "Read current implementation", "status": "pending"},
                {"name": "Implement fix", "status": "pending"},
                {"name": "Run tests", "status": "pending"},
            ],
        )
        self.assertEqual(tasks[0]["reviewCycles"], 0)
        self.assertEqual(tasks[0]["maxReviewCycles"], 5)
        self.assertIsNone(tasks[0]["startedAt"])
        self.assertIsNone(tasks[0]["completedAt"])
        self.assertIsNone(tasks[0]["lastProgressAt"])

        spec_path = self.objectives_dir / objective["id"] / "tasks" / "task-1" / "spec.md"
        self.assertTrue(spec_path.is_file())
        spec_text = spec_path.read_text(encoding="utf-8")
        self.assertIn("# Fix token expiry check", spec_text)
        self.assertIn("- TokenManager.swift", spec_text)
        self.assertIn("1. Read current implementation", spec_text)


if __name__ == "__main__":
    unittest.main()
