import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from cmux_harness import objectives
from cmux_harness.orchestrator import Orchestrator


def _patch_objective_git(test_case):
    patcher = patch("cmux_harness.objectives.subprocess.run")
    mock_run = patcher.start()
    mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
    test_case.addCleanup(patcher.stop)
    return mock_run


class TestOrchestrator(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.mock_objectives_run = _patch_objective_git(self)
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

    def test_start_objective_restarts_failed_active_objective(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(objective["id"], {"status": "failed"})
        self.orchestrator._active_objective_id = objective["id"]

        with patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.assertTrue(self.orchestrator.start_objective(objective["id"]))

        mock_thread.assert_called_once()
        self.assertEqual(self.orchestrator.get_active_objective_id(), objective["id"])
        self.assertEqual(objectives.read_objective(objective["id"])["status"], "planning")

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

    def test_log_event_persists_jsonl_and_filters(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        self.orchestrator._log_event(objective["id"], "info", "planning_start", {"attempt": 1})
        self.orchestrator._log_event(objective["id"], "error", "planning_failure", {"reason": "timeout"})

        debug_path = self.objectives_dir / objective["id"] / "debug.jsonl"
        lines = debug_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        parsed = [json.loads(line) for line in lines]
        self.assertEqual(parsed[0]["event"], "planning_start")
        self.assertEqual(parsed[1]["level"], "error")
        self.assertEqual(len(self.orchestrator.get_debug_entries(objective["id"], limit=1)), 1)
        self.assertEqual(len(self.orchestrator.get_debug_entries(objective["id"], level="error")), 1)

    def test_stop_and_cleanup_closes_task_workspaces_and_removes_worktree(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "tasks": [
                    {"id": "task-1", "workspaceId": "ws-1"},
                    {"id": "task-2", "workspaceId": "ws-2"},
                    {"id": "task-3", "workspaceId": "ws-1"},
                ]
            },
        )
        self.orchestrator._active_objective_id = objective["id"]

        with patch("cmux_harness.orchestrator.cmux_api._v2_request", return_value={"ok": True}) as mock_request, \
                patch("cmux_harness.orchestrator.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
            self.assertTrue(self.orchestrator.stop_and_cleanup(objective["id"]))

        self.assertEqual(
            mock_request.call_args_list,
            [
                unittest.mock.call("workspace.close", {"workspace_id": "ws-1"}),
                unittest.mock.call("workspace.close", {"workspace_id": "ws-2"}),
            ],
        )
        mock_run.assert_called_once_with(
            ["git", "-C", "/tmp/project", "worktree", "remove", objective["worktreePath"], "--force"],
            capture_output=True,
            text=True,
            check=True,
        )


class TestAPIEndpoints(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.mock_objectives_run = _patch_objective_git(self)
        self.engine = object()
        self.orchestrator = Orchestrator(self.engine)

    def test_start_objective_via_orchestrator(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        with patch("cmux_harness.orchestrator.threading.Thread"):
            started = self.orchestrator.start_objective(objective["id"])

        self.assertTrue(started)
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "planning")

    def test_get_messages_returns_messages(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        with patch("cmux_harness.orchestrator.threading.Thread"):
            self.orchestrator.start_objective(objective["id"])

        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["type"], "system")
        self.assertIn("Starting objective: Ship feature", messages[0]["content"])

    def test_get_messages_filters_by_after(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        with patch("cmux_harness.orchestrator.threading.Thread"):
            self.orchestrator.start_objective(objective["id"])

        first_message = self.orchestrator.get_messages(objective["id"])[0]
        self.orchestrator._append_message(objective["id"], "system", "Second message")

        messages = self.orchestrator.get_messages(objective["id"], after=first_message["timestamp"])
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["content"], "Second message")

    def test_handle_human_input_logs_message(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        self.orchestrator.handle_human_input(objective["id"], "Need a change here")

        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["type"], "user")
        self.assertEqual(messages[0]["content"], "Need a change here")

    def test_run_planning_defaults_to_ten_minute_timeout(self):
        self.assertEqual(Orchestrator._run_planning.__defaults__, (10, 36, 90))

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
        self.mock_objectives_run = _patch_objective_git(self)
        self.orchestrator = Orchestrator(object())

    def _create_objective(self):
        return objectives.create_objective("Implement orchestrator planning", str(self.project_dir))

    def test_run_planning_success(self):
        objective = self._create_objective()
        plan_path = Path(objective["worktreePath"]) / "plan.md"
        plan_path.parent.mkdir(parents=True, exist_ok=True)
        plan_path.write_text("## Task 1: First\n## Task 2: Second\n", encoding="utf-8")
        tasks = [
            {"id": "task-1", "title": "First", "status": "queued"},
            {"id": "task-2", "title": "Second", "status": "queued"},
        ]
        launch_ready = Mock()
        self.orchestrator._launch_ready_tasks = launch_ready

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)) as mock_create_workspace, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send_prompt, \
                patch("cmux_harness.orchestrator.planner.parse_plan", return_value={"tasks": [{"id": "task-1"}, {"id": "task-2"}]}), \
                patch("cmux_harness.orchestrator.planner.plan_to_tasks", return_value=tasks), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"], _poll_interval=0, _grace_polls=0, _max_polls=2)

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "executing")
        self.assertEqual(updated["tasks"], tasks)
        self.assertTrue(any("Plan ready: 2 tasks identified." in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))
        # Called twice: planning prompt + /exit cleanup
        self.assertEqual(mock_send_prompt.call_count, 2)
        self.assertIn("/exit", mock_send_prompt.call_args_list[-1].args[1])
        self.assertEqual(mock_create_workspace.call_args.args[1], objective["worktreePath"])
        launch_ready.assert_called_once_with(objective["id"])

    def test_run_planning_no_plan_file(self):
        objective = self._create_objective()

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"], _poll_interval=0, _grace_polls=0, _max_polls=2)

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")
        self.assertTrue(any("exited before writing plan.md" in msg["content"] or "timed out waiting for plan.md" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))

    def test_run_planning_parse_failure(self):
        objective = self._create_objective()
        raw_plan = "## Task 1: Unparseable\n- Something odd\n"
        Path(objective["worktreePath"]).mkdir(parents=True, exist_ok=True)
        (Path(objective["worktreePath"]) / "plan.md").write_text(raw_plan, encoding="utf-8")

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-planner", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True), \
                patch("cmux_harness.orchestrator.planner.parse_plan", return_value={"error": "parse_failed", "raw_plan": raw_plan}), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator._run_planning(objective["id"], _poll_interval=0, _grace_polls=0, _max_polls=2)

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
        self.mock_objectives_run = _patch_objective_git(self)
        self.orchestrator = Orchestrator(object())

    def _create_objective(self, tasks):
        objective = objectives.create_objective("Launch tasks", str(self.project_dir))
        objectives.update_objective(objective["id"], {"tasks": tasks, "status": "executing"})
        return objective

    def _create_task_files(self, objective_id, task_id, spec="spec", context=""):
        objectives.write_task_file(objective_id, task_id, "spec.md", spec)
        objectives.write_task_file(objective_id, task_id, "context.md", context)

    def test_launch_ready_tasks_uses_objective_worktree_and_launches_one_task_at_a_time(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "startedAt": None},
            {"id": "task-2", "title": "Second task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        Path(objective["worktreePath"]).mkdir(parents=True, exist_ok=True)

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-1", True)) as mock_workspace, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual([task["status"] for task in updated["tasks"]], ["executing", "queued"])
        self.assertEqual(updated["tasks"][0]["workspaceId"], "fake-uuid-1")
        self.assertIsNone(updated["tasks"][1]["workspaceId"])
        self.assertEqual(updated["tasks"][0]["worktreePath"], objective["worktreePath"])
        self.assertIsNone(updated["tasks"][1]["worktreePath"])
        mock_workspace.assert_called_once_with(
            "Worker: First task",
            objective["worktreePath"],
            objective_id=objective["id"],
            purpose="task",
            task_id="task-1",
        )
        system_messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "system"]
        self.assertEqual(len(system_messages), 2)
        self.assertEqual((Path(objective["worktreePath"]) / "spec.md").read_text(encoding="utf-8"), "spec")

    def test_launch_ready_tasks_skips_blocked_tasks(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "startedAt": None},
            {"id": "task-2", "title": "Second task", "status": "queued", "dependsOn": ["task-1"], "workspaceId": None, "worktreePath": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        Path(objective["worktreePath"]).mkdir(parents=True, exist_ok=True)

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-1", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][0]["status"], "executing")
        self.assertEqual(updated["tasks"][1]["status"], "queued")

    def test_launch_ready_tasks_launches_after_dependency_complete(self):
        tasks = [
            {"id": "task-1", "title": "Completed task", "status": "completed", "dependsOn": [], "workspaceId": None, "worktreePath": None, "startedAt": None},
            {"id": "task-2", "title": "Dependent task", "status": "queued", "dependsOn": ["task-1"], "workspaceId": None, "worktreePath": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        self._create_task_files(objective["id"], "task-2")
        objectives.write_task_file(objective["id"], "task-1", "result.md", "Task one result")
        Path(objective["worktreePath"]).mkdir(parents=True, exist_ok=True)

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-2", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][1]["status"], "executing")
        self.assertEqual(updated["tasks"][1]["worktreePath"], objective["worktreePath"])
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


class TestPollTasks(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.project_dir = Path(self.tmpdir.name) / "project"
        self.project_dir.mkdir()
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.mock_objectives_run = _patch_objective_git(self)
        self.orchestrator = Orchestrator(object())

    def _create_objective(self, tasks):
        objective = objectives.create_objective("Monitor tasks", str(self.project_dir))
        objectives.update_objective(objective["id"], {"tasks": tasks, "status": "executing"})
        return objective

    def test_poll_tasks_auto_approves_routine_prompt(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])
        objectives.write_task_file(objective["id"], "task-1", "spec.md", "Routine task")

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Do you want to create file.ts?"), \
                patch("cmux_harness.orchestrator.cmux_api._v2_request") as mock_v2, \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}):
            self.orchestrator.poll_tasks(objective["id"])

        mock_v2.assert_any_call("surface.send_key", {"workspace_id": "ws-1", "key": "enter"})
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "system" and "auto-approved" in msg["content"] for msg in messages))

    def test_poll_tasks_escalates_complex_prompt(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])
        objectives.write_task_file(objective["id"], "task-1", "spec.md", "Complex task")

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Choose one option"), \
                patch("cmux_harness.orchestrator.detection.detect_prompt", return_value={"type": "yesno"}), \
                patch("cmux_harness.orchestrator.approval.classify_approval", return_value={"decision": "ESCALATE", "reason": "requires human judgment"}), \
                patch("cmux_harness.orchestrator.approval.should_auto_approve", return_value=False), \
                patch("cmux_harness.orchestrator.cmux_api.cmux_send_to_workspace") as mock_send, \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}):
            self.orchestrator.poll_tasks(objective["id"])

        mock_send.assert_not_called()
        messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "approval"]
        self.assertEqual(len(messages), 1)
        self.assertIn("needs your input", messages[0]["content"])
        self.assertEqual(messages[0]["metadata"]["screen_preview"], "Choose one option")

    def test_poll_tasks_detects_completion(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value=""), \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": True, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False):
            self.orchestrator.poll_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][0]["status"], "reviewing")
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "progress" and "starting review" in msg["content"] for msg in messages))

    def test_poll_tasks_updates_checkpoints(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])
        checkpoints = [
            {"name": "Investigate", "status": "done"},
            {"name": "Implement", "status": "in_progress"},
        ]

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="screen"), \
                patch("cmux_harness.orchestrator.detection.detect_prompt", return_value={"type": "none"}), \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={
                    "has_result": False,
                    "has_progress_update": True,
                    "progress_mtime": 123.0,
                    "checkpoints": checkpoints,
                }), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}):
            self.orchestrator.poll_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(
            updated["tasks"][0]["checkpoints"],
            [{"name": "Investigate", "status": "done"}, {"name": "Implement", "status": "in_progress"}],
        )
        self.assertIn("lastProgressAt", updated["tasks"][0])
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "progress" and "checkpoint 'Implement'" in msg["content"] for msg in messages))

    def test_poll_tasks_detects_stalled(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])
        self.orchestrator._task_last_progress["task-1"] = 0.0

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="stalled screen"), \
                patch("cmux_harness.orchestrator.detection.detect_prompt", return_value={"type": "none"}), \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "stalled", "reason": "no activity", "elapsed_minutes": 10.0}):
            self.orchestrator.poll_tasks(objective["id"])

        messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "alert"]
        self.assertEqual(len(messages), 1)
        self.assertIn("appears stalled", messages[0]["content"])
        self.assertEqual(messages[0]["metadata"]["screen_preview"], "stalled screen")

    def test_poll_tasks_skips_non_executing_tasks(self):
        tasks = [
            {"id": "task-1", "status": "queued", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)},
            {"id": "task-2", "status": "completed", "workspaceId": "ws-2", "worktreePath": str(self.project_dir)},
        ]
        objective = self._create_objective(tasks)

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace") as mock_read, \
                patch("cmux_harness.orchestrator.monitor.check_progress") as mock_progress:
            self.orchestrator.poll_tasks(objective["id"])

        mock_read.assert_not_called()
        mock_progress.assert_not_called()


class TestReviewRework(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.project_dir = Path(self.tmpdir.name) / "project"
        self.project_dir.mkdir()
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.mock_objectives_run = _patch_objective_git(self)
        self.orchestrator = Orchestrator(object())
        self.orchestrator._active_objective_id = "active-objective"

    def _create_objective(self, tasks, status="executing"):
        objective = objectives.create_objective("Review tasks", str(self.project_dir))
        objectives.update_objective(objective["id"], {"tasks": tasks, "status": status})
        return objective

    def _create_task_files(self, objective_id, task_id, result_text="task result", spec_text="task spec"):
        objectives.write_task_file(objective_id, task_id, "result.md", result_text)
        objectives.write_task_file(objective_id, task_id, "spec.md", spec_text)

    def test_run_review_passes_clean_review(self):
        worktree = self.project_dir / "wt-pass"
        worktree.mkdir()
        task = {
            "id": "task-1",
            "title": "Review me",
            "status": "reviewing",
            "workspaceId": "ws-1",
            "worktreePath": str(worktree),
            "reviewCycles": 0,
            "maxReviewCycles": 5,
        }
        objective = self._create_objective([task])
        self._create_task_files(objective["id"], "task-1")

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "summary": "Good work",
                    "issues": [],
                    "confidence": "high",
                    "readyForPR": True,
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=False), \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch_ready, \
                patch.object(self.orchestrator, "_complete_objective") as mock_complete:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "completed")
        self.assertEqual(updated_task["reviewCycles"], 1)
        self.assertIn("completedAt", updated_task)
        self.assertEqual(
            json.loads(objectives.read_task_file(objective["id"], "task-1", "review.json"))["summary"],
            "Good work",
        )
        self.assertTrue(any("review passed" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))
        mock_launch_ready.assert_called_once_with(objective["id"])
        mock_complete.assert_called_once_with(objective["id"])

    def test_run_review_triggers_rework(self):
        worktree = self.project_dir / "wt-rework"
        worktree.mkdir()
        task = {
            "id": "task-1",
            "title": "Needs fixes",
            "status": "reviewing",
            "workspaceId": "ws-1",
            "worktreePath": str(worktree),
            "reviewCycles": 0,
            "maxReviewCycles": 5,
        }
        objective = self._create_objective([task])
        self._create_task_files(objective["id"], "task-1")

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "summary": "Needs work",
                    "issues": ["Fix formatting"],
                    "confidence": "medium",
                    "readyForPR": False,
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.can_retry_review", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.build_review_rework_summary", return_value=(["Fix formatting"], "Clean up code")), \
                patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="shell prompt"), \
                patch("cmux_harness.orchestrator.detection.detect_claude_session", return_value=False), \
                patch("cmux_harness.orchestrator.cmux_api.cmux_send_to_workspace") as mock_send_text, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True) as mock_wait, \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace") as mock_send_prompt:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "executing")
        self.assertEqual(updated_task["reviewCycles"], 1)
        mock_send_text.assert_called_once_with(
            0,
            0,
            text=f"cd {worktree} && claude\n",
            workspace_uuid="ws-1",
        )
        mock_wait.assert_called_once_with(
            "ws-1",
            objective_id=objective["id"],
            purpose="rework",
            task_id="task-1",
        )
        mock_send_prompt.assert_called_once()
        self.assertTrue(
            any("sending back for fixes" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"]))
        )

    def test_run_review_escalates_after_max_cycles(self):
        worktree = self.project_dir / "wt-fail"
        worktree.mkdir()
        task = {
            "id": "task-1",
            "title": "Maxed out",
            "status": "reviewing",
            "workspaceId": "ws-1",
            "worktreePath": str(worktree),
            "reviewCycles": 4,
            "maxReviewCycles": 5,
        }
        objective = self._create_objective([task])
        self._create_task_files(objective["id"], "task-1")

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "summary": "Still broken",
                    "issues": ["Fix formatting"],
                    "confidence": "low",
                    "readyForPR": False,
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.can_retry_review", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.build_review_rework_summary", return_value=(["Fix formatting"], "Clean up code")):
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "failed")
        self.assertEqual(updated_task["reviewCycles"], 5)
        alerts = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "alert"]
        self.assertEqual(len(alerts), 1)
        self.assertIn("Needs your attention", alerts[0]["content"])
        self.assertEqual(alerts[0]["metadata"]["issues"], ["Fix formatting"])

    def test_complete_objective(self):
        tasks = [
            {"id": "task-1", "status": "completed", "reviewCycles": 1},
            {"id": "task-2", "status": "completed", "reviewCycles": 2},
        ]
        objective = self._create_objective(tasks, status="executing")
        self.orchestrator._active_objective_id = objective["id"]
        objectives.write_task_file(objective["id"], "task-1", "result.md", "Task one done")
        objectives.write_task_file(objective["id"], "task-2", "result.md", "Task two done")

        with patch("cmux_harness.orchestrator.claude_cli.run_haiku", return_value="Project summary text"):
            self.orchestrator._complete_objective(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "completed")
        messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "completion"]
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["metadata"]["summary"], "Project summary text")
        self.assertEqual(messages[0]["metadata"]["total_review_cycles"], 3)
        self.assertEqual(messages[0]["metadata"]["rework_count"], 1)
        self.assertIsNone(self.orchestrator.get_active_objective_id())

    def test_handle_human_input_sends_approval(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-approve"}
        objective = self._create_objective([task])

        with patch("cmux_harness.orchestrator.cmux_api.cmux_send_to_workspace") as mock_send:
            self.orchestrator.handle_human_input(
                objective["id"],
                "Approve it",
                context={"task_id": "task-1", "approval_action": "y\n"},
            )

        mock_send.assert_called_once_with(0, 0, text="y\n", workspace_uuid="ws-approve")
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[-1]["content"], "Sent 'y\n' to Task task-1")

    def test_handle_human_input_takes_over(self):
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-approve"}
        objective = self._create_objective([task])

        self.orchestrator.handle_human_input(
            objective["id"],
            "I will take this one",
            context={"task_id": "task-1", "take_over": True},
        )

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["tasks"][0]["status"], "failed")
        self.assertEqual(updated["tasks"][0]["note"], "Taken over by human")
        self.assertTrue(
            any("taken over by human" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"]))
        )

    def test_handle_human_input_restarts_failed_objective_on_retry_request(self):
        objective = self._create_objective([], status="failed")
        self.orchestrator._active_objective_id = objective["id"]

        with patch.object(self.orchestrator, "start_objective", wraps=self.orchestrator.start_objective) as mock_start, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_human_input(objective["id"], "Please retry this")

        mock_start.assert_called_once_with(objective["id"])
        mock_thread.assert_called_once()
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[0]["type"], "user")
        self.assertEqual(messages[0]["content"], "Please retry this")
        self.assertEqual(objectives.read_objective(objective["id"])["status"], "planning")


if __name__ == "__main__":
    unittest.main()
