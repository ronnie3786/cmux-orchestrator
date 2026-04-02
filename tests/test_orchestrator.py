import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

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

        with patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.assertTrue(self.orchestrator.start_objective(valid["id"]))
        mock_thread.assert_called_once()
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
        with patch("cmux_harness.orchestrator.threading.Thread"):
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
        with patch("cmux_harness.orchestrator.threading.Thread"):
            self.orchestrator.start_objective(objective["id"])

        self.assertFalse(self.orchestrator.is_orchestrated_workspace("ws-999"))
        self.assertTrue(self.orchestrator.is_orchestrated_workspace("ws-123"))

    def test_stop_objective_clears_active_and_appends_message(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        with patch("cmux_harness.orchestrator.threading.Thread"):
            self.orchestrator.start_objective(objective["id"])

        self.assertFalse(self.orchestrator.stop_objective("wrong-id"))
        self.assertTrue(self.orchestrator.stop_objective(objective["id"]))
        self.assertIsNone(self.orchestrator.get_active_objective_id())
        self.assertEqual(self.orchestrator.get_messages(objective["id"])[-1]["content"], "Objective stopped.")

class TestPlanningPipeline(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.project_dir = Path(self.tmpdir.name) / "project"
        self.project_dir.mkdir()
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.orchestrator = Orchestrator(object())

    def _create_objective(self):
        return objectives.create_objective("Implement orchestrator planning", str(self.project_dir))

    def test_run_planning_success(self):
        objective = self._create_objective()
        plan_path = self.project_dir / "plan.md"
        plan_path.write_text("## Task 1: First\n## Task 2: Second\n", encoding="utf-8")
        tasks = [
            {"id": "task-1", "title": "First", "status": "queued"},
            {"id": "task-2", "title": "Second", "status": "queued"},
        ]
        launch_ready = Mock()
        self.orchestrator._launch_ready_tasks = launch_ready

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send_prompt, \
                patch("cmux_harness.orchestrator.planner.parse_plan", return_value={"tasks": [{"id": "task-1"}, {"id": "task-2"}]}), \
                patch("cmux_harness.orchestrator.planner.plan_to_tasks", return_value=tasks), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "executing")
        self.assertEqual(updated["tasks"], tasks)
        self.assertTrue(any("Plan ready: 2 tasks identified." in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))
        mock_send_prompt.assert_called_once()
        launch_ready.assert_called_once_with(objective["id"])

    def test_run_planning_no_plan_file(self):
        objective = self._create_objective()

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")
        self.assertTrue(any("exited before writing plan.md" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))

    def test_run_planning_parse_failure(self):
        objective = self._create_objective()
        raw_plan = "## Task 1: Unparseable\n- Something odd\n"
        (self.project_dir / "plan.md").write_text(raw_plan, encoding="utf-8")

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True), \
                patch("cmux_harness.orchestrator.planner.parse_plan", return_value={"error": "parse_failed", "raw_plan": raw_plan}), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")
        self.assertTrue(any(raw_plan in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))


class TestTaskLauncher(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.project_dir = Path(self.tmpdir.name) / "project"
        self.project_dir.mkdir()
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.orchestrator = Orchestrator(object())

    def _create_objective(self, tasks):
        objective = objectives.create_objective("Launch tasks", str(self.project_dir))
        objectives.update_objective(objective["id"], {"tasks": tasks, "status": "executing"})
        return objective

    def _create_task_files(self, objective_id, task_id, spec="spec", context=""):
        objectives.write_task_file(objective_id, task_id, "spec.md", spec)
        objectives.write_task_file(objective_id, task_id, "context.md", context)

    def test_launch_ready_tasks_launches_independent_tasks(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
            {"id": "task-2", "title": "Second task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        worktree_one = self.project_dir / "wt-1"
        worktree_two = self.project_dir / "wt-2"
        worktree_one.mkdir()
        worktree_two.mkdir()

        with patch("cmux_harness.orchestrator.worker.create_worktree", side_effect=[str(worktree_one), str(worktree_two)]), \
                patch.object(self.orchestrator, "_create_worker_workspace", side_effect=[("fake-uuid-1", True), ("fake-uuid-2", True)]), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual([task["status"] for task in updated["tasks"]], ["executing", "executing"])
        self.assertEqual(updated["tasks"][0]["workspaceId"], "fake-uuid-1")
        self.assertEqual(updated["tasks"][1]["workspaceId"], "fake-uuid-2")
        self.assertEqual(updated["tasks"][0]["worktreePath"], str(worktree_one))
        self.assertEqual(updated["tasks"][1]["worktreePath"], str(worktree_two))
        system_messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "system"]
        self.assertEqual(len(system_messages), 2)

    def test_launch_ready_tasks_skips_blocked_tasks(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
            {"id": "task-2", "title": "Second task", "status": "queued", "dependsOn": ["task-1"], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        worktree_one = self.project_dir / "wt-1"
        worktree_one.mkdir()

        with patch("cmux_harness.orchestrator.worker.create_worktree", return_value=str(worktree_one)), \
                patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-1", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][0]["status"], "executing")
        self.assertEqual(updated["tasks"][1]["status"], "queued")

    def test_launch_ready_tasks_launches_after_dependency_complete(self):
        tasks = [
            {"id": "task-1", "title": "Completed task", "status": "completed", "dependsOn": [], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
            {"id": "task-2", "title": "Dependent task", "status": "queued", "dependsOn": ["task-1"], "workspaceId": None, "worktreePath": None, "worktreeBranch": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        objectives.write_task_file(objective["id"], "task-1", "result.md", "Task one result")
        worktree_two = self.project_dir / "wt-2"
        worktree_two.mkdir()

        with patch("cmux_harness.orchestrator.worker.create_worktree", return_value=str(worktree_two)), \
                patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-2", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][1]["status"], "executing")
        context = objectives.read_task_file(objective["id"], "task-2", "context.md")
        self.assertIn("Task one result", context)

    def test_assemble_context_builds_from_dependencies(self):
        tasks = [
            {"id": "task-1", "title": "Completed task", "status": "completed", "dependsOn": []},
            {"id": "task-2", "title": "Dependent task", "status": "queued", "dependsOn": ["task-1"]},
        ]
        objective = self._create_objective(tasks)
        objectives.write_task_file(objective["id"], "task-1", "result.md", "Dependency result")

        self.orchestrator._assemble_context(objective["id"], tasks[1])

        context = objectives.read_task_file(objective["id"], "task-2", "context.md")
        self.assertIn("# Context from completed tasks", context)
        self.assertIn("## Task task-1: Completed task", context)
        self.assertIn("Dependency result", context)

    def test_assemble_context_handles_missing_result(self):
        tasks = [
            {"id": "task-1", "title": "Completed task", "status": "completed", "dependsOn": []},
            {"id": "task-2", "title": "Dependent task", "status": "queued", "dependsOn": ["task-1"]},
        ]
        objective = self._create_objective(tasks)

        self.orchestrator._assemble_context(objective["id"], tasks[1])

        context = objectives.read_task_file(objective["id"], "task-2", "context.md")
        self.assertEqual(context, "")


if __name__ == "__main__":
    unittest.main()
