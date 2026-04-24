import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

from cmux_harness import objectives
from cmux_harness import workspaces
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
                "plannerWorkspaceId": "ws-planner",
                "plannerArchivedWorkspaceId": "ws-planner-archived",
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
                unittest.mock.call("workspace.close", {"workspace_id": "ws-planner"}),
                unittest.mock.call("workspace.close", {"workspace_id": "ws-planner-archived"}),
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

    def test_handle_human_input_routes_to_active_orchestrator_session(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "status": "completed",
                "orchestratorSessionId": "ws-orch",
                "orchestratorSessionActive": True,
            },
        )

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="existing screen"), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_human_input(objective["id"], "Need a change here")

        mock_send.assert_called_once_with("ws-orch", "Need a change here")
        mock_thread.assert_called_once()
        self.assertEqual(mock_thread.call_args.kwargs["target"], self.orchestrator._capture_orchestrator_response)
        self.assertEqual(
            mock_thread.call_args.kwargs["args"],
            (objective["id"], "ws-orch", "existing screen", "Need a change here"),
        )
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["type"], "user")
        self.assertEqual(messages[0]["content"], "Need a change here")
        updated = objectives.read_objective(objective["id"])
        self.assertTrue(updated["orchestratorSessionActive"])
        self.assertEqual(updated["orchestratorSessionId"], "ws-orch")

    def test_handle_human_input_records_resolved_approval_without_newline_artifact(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.update_objective(
            objective["id"],
            {
                "status": "executing",
                "tasks": [{"id": "task-1", "workspaceId": "ws-task"}],
            },
        )

        with patch("cmux_harness.orchestrator.cmux_api.cmux_send_to_workspace") as mock_send:
            self.orchestrator.handle_human_input(
                objective["id"],
                "Approved: y",
                context={"task_id": "task-1", "approval_action": "y\n", "approval_message_id": "approval-1"},
            )

        mock_send.assert_called_once_with(0, 0, text="y\n", workspace_uuid="ws-task")
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[-1]["type"], "approval_resolved")
        self.assertEqual(messages[-1]["metadata"]["approval_message_id"], "approval-1")
        self.assertIn("human approved with 'y' — Claude resumed", messages[-1]["content"])

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
        self.assertEqual(updated["status"], "plan_review")
        self.assertEqual(updated["tasks"], tasks)
        self.assertEqual(updated["plannerWorkspaceId"], "ws-planner")
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "plan_review" for msg in messages))
        # Called once: planning prompt only. Planner workspace stays alive for review.
        self.assertEqual(mock_send_prompt.call_count, 1)
        self.assertEqual(mock_create_workspace.call_args.args[1], objective["worktreePath"])
        launch_ready.assert_not_called()

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

    def test_approve_plan_archives_planner_and_starts_contract_negotiation(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "plan_review",
                "plannerWorkspaceId": "ws-planner",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )

        with patch.object(self.orchestrator, "_archive_workspace") as mock_archive, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            approved = self.orchestrator.approve_plan(objective["id"])

        self.assertTrue(approved)
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "negotiating_contracts")
        self.assertIsNone(updated["plannerWorkspaceId"])
        self.assertEqual(updated["plannerArchivedWorkspaceId"], "ws-planner")
        mock_archive.assert_called_once_with(objective["id"], "ws-planner", "plan_approved")
        mock_thread.assert_called_once_with(
            target=self.orchestrator._negotiate_contracts,
            args=(objective["id"],),
            daemon=True,
        )
        mock_thread.return_value.start.assert_called_once_with()
        self.assertTrue(
            any(
                "Plan approved, negotiating sprint contracts..." in msg["content"]
                for msg in self.orchestrator.get_messages(objective["id"])
            )
        )

    def test_approve_contracts_transitions_to_executing(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "contract_review",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )

        with patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch:
            approved = self.orchestrator.approve_contracts(objective["id"])

        self.assertTrue(approved)
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "executing")
        mock_launch.assert_called_once_with(objective["id"])
        self.assertTrue(
            any(
                "Contracts approved, launching tasks..." in msg["content"]
                for msg in self.orchestrator.get_messages(objective["id"])
            )
        )

    def test_negotiate_contracts_auto_starts_execution_when_contract_review_disabled(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "negotiating_contracts",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )
        self.orchestrator.engine = Mock(contract_review_enabled=False)
        contract_text = """## Acceptance Criteria
1. Feature works.

## Build Verification
/exp-project-run

## Functional Test Hints
Run the flow.

## Pass/Fail Threshold
Pass if the task behaves as specified.
"""

        with patch("cmux_harness.orchestrator.claude_cli.run_sonnet", side_effect=[
                contract_text,
                {"verdict": "pass", "summary": "Contract is aligned and testable.", "issues": []},
            ]), \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch:
            self.orchestrator._negotiate_contracts(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "executing")
        mock_launch.assert_called_once_with(objective["id"])
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "contract_review" for msg in messages))
        self.assertTrue(any("drafting sprint contract" in msg["content"] for msg in messages if msg["type"] == "progress"))
        self.assertTrue(any("evaluating sprint contract" in msg["content"] for msg in messages if msg["type"] == "progress"))
        self.assertTrue(any("contract approved by AI evaluator" in msg["content"] for msg in messages if msg["type"] == "progress"))
        self.assertTrue(any("AI contract evaluator approved the contracts" in msg["content"] for msg in messages if msg["type"] == "system"))

    def test_negotiate_contracts_waits_for_human_review_when_enabled(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "negotiating_contracts",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )
        self.orchestrator.engine = Mock(contract_review_enabled=True)
        contract_text = """## Acceptance Criteria
1. Feature works.

## Build Verification
/exp-project-run

## Functional Test Hints
Run the flow.

## Pass/Fail Threshold
Pass if the task behaves as specified.
"""

        with patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value=contract_text), \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch:
            self.orchestrator._negotiate_contracts(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "contract_review")
        mock_launch.assert_not_called()

    def test_negotiate_contracts_regenerates_until_evaluator_passes(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "negotiating_contracts",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )
        self.orchestrator.engine = Mock(contract_review_enabled=False)
        weak_contract = """## Acceptance Criteria
1. Do the thing.

## Build Verification
/exp-project-run

## Functional Test Hints
- Test it.

## Pass/Fail Threshold
- Should probably work.
"""
        improved_contract = """## Acceptance Criteria
1. The feature works end to end for the primary flow.

## Build Verification
- /exp-project-run

## Functional Test Hints
- Run the full user flow in Maestro and verify success and failure paths.

## Pass/Fail Threshold
- Fail if the flow does not work end to end or any acceptance criterion lacks evidence.
"""

        with patch("cmux_harness.orchestrator.claude_cli.run_sonnet", side_effect=[
                weak_contract,
                {"verdict": "fail", "summary": "Too vague.", "issues": ["Acceptance criteria are not concrete enough."]},
                improved_contract,
                {"verdict": "pass", "summary": "Looks good.", "issues": []},
            ]), \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch:
            self.orchestrator._negotiate_contracts(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "executing")
        mock_launch.assert_called_once_with(objective["id"])
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any("AI contract evaluator requested changes" in msg["content"] for msg in messages if msg["type"] == "system"))
        final_contract = objectives.read_task_file(objective["id"], "task-1", "contract.md")
        self.assertIn("The feature works end to end", final_contract)

    def test_negotiate_contracts_falls_back_to_human_review_when_evaluator_never_passes(self):
        objective = self._create_objective()
        objectives.update_objective(
            objective["id"],
            {
                "status": "negotiating_contracts",
                "tasks": [{"id": "task-1", "title": "First", "status": "queued"}],
            },
        )
        self.orchestrator.engine = Mock(contract_review_enabled=False)
        weak_contract = """## Acceptance Criteria
1. Do the thing.

## Build Verification
/exp-project-run

## Functional Test Hints
- Test it.

## Pass/Fail Threshold
- Should probably work.
"""

        with patch("cmux_harness.orchestrator.claude_cli.run_sonnet", side_effect=[
                weak_contract,
                {"verdict": "fail", "summary": "Too vague.", "issues": ["Acceptance criteria are not concrete enough."]},
                weak_contract,
                {"verdict": "fail", "summary": "Still too vague.", "issues": ["Acceptance criteria are not concrete enough."]},
                weak_contract,
                {"verdict": "fail", "summary": "Still too vague.", "issues": ["Acceptance criteria are not concrete enough."]},
            ]), \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch:
            self.orchestrator._negotiate_contracts(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "contract_review")
        mock_launch.assert_not_called()
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertTrue(any(msg["type"] == "alert" and "Human review is required" in msg["content"] for msg in messages))

    def test_handle_human_input_revises_plan_during_plan_review(self):
        objective = self._create_objective()
        plan_path = Path(objective["worktreePath"]) / "plan.md"
        plan_path.parent.mkdir(parents=True, exist_ok=True)
        plan_path.write_text("original plan", encoding="utf-8")
        objectives.update_objective(
            objective["id"],
            {
                "status": "plan_review",
                "plannerWorkspaceId": "ws-planner",
            },
        )
        revised_parsed = {
            "tasks": [
                {
                    "id": "task-1",
                    "title": "Revised task",
                    "userStory": "Users can complete the revised flow.",
                    "deliverables": ["Revised flow behavior"],
                    "dependsOn": [],
                    "checkpoints": ["Revise plan"],
                }
            ]
        }
        revised_tasks = [
            {
                "id": "task-1",
                "title": "Revised task",
                "userStory": "Users can complete the revised flow.",
                "deliverables": ["Revised flow behavior"],
                "status": "queued",
                "dependsOn": [],
                "workspaceId": None,
                "worktreePath": None,
                "checkpoints": [{"name": "Revise plan", "status": "pending"}],
                "reviewCycles": 0,
                "maxReviewCycles": 3,
                "startedAt": None,
                "completedAt": None,
                "lastProgressAt": None,
            }
        ]

        with patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread, \
                patch("cmux_harness.orchestrator.planner.parse_plan", return_value=revised_parsed), \
                patch("cmux_harness.orchestrator.planner.plan_to_tasks", return_value=revised_tasks):
            self.orchestrator.handle_human_input(objective["id"], "Please split task 1")
            poll_target = mock_thread.call_args.kwargs["target"]
            poll_args = mock_thread.call_args.kwargs["args"]
            plan_path.write_text("revised plan", encoding="utf-8")
            poll_target(*poll_args, _poll_interval=0, _max_seconds=1)

        self.assertIn("Please split task 1", mock_send.call_args.args[1])
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "plan_review")
        self.assertEqual(updated["tasks"], revised_tasks)
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[0]["type"], "user")
        self.assertTrue(any(msg["type"] == "system" and "Revising plan based on your feedback" in msg["content"] for msg in messages))
        self.assertTrue(any(msg["type"] == "plan_review" and "Plan updated" in msg["content"] for msg in messages))


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
        self.orchestrator._task_last_progress["task-1"] = 123.0
        self.orchestrator._task_screen_cache["task-1"] = "stale screen"

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
        self.assertNotIn("task-1", self.orchestrator._task_last_progress)
        self.assertNotIn("task-1", self.orchestrator._task_screen_cache)
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

    def test_launch_ready_tasks_clears_stale_runtime_files_before_launch(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "queued", "dependsOn": [], "workspaceId": None, "worktreePath": None, "startedAt": None},
        ]
        objective = self._create_objective(tasks)
        self._create_task_files(objective["id"], "task-1")
        worktree = Path(objective["worktreePath"])
        worktree.mkdir(parents=True, exist_ok=True)
        (worktree / "progress.md").write_text("old progress\n", encoding="utf-8")
        (worktree / "result.md").write_text("stale result\n", encoding="utf-8")
        objectives.write_task_file(objective["id"], "task-1", "progress.md", "old task progress")
        objectives.write_task_file(objective["id"], "task-1", "result.md", "old task result")

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("fake-uuid-1", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True):
            self.orchestrator._launch_ready_tasks(objective["id"])

        self.assertEqual((worktree / "progress.md").read_text(encoding="utf-8"), "")
        self.assertEqual((worktree / "result.md").read_text(encoding="utf-8"), "")
        self.assertEqual(objectives.read_task_file(objective["id"], "task-1", "progress.md"), "")
        self.assertEqual(objectives.read_task_file(objective["id"], "task-1", "result.md"), "")

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

    def test_poll_tasks_no_longer_does_approval(self):
        """Approval is now handled by PreToolUse hooks, not polling."""
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Do you want to create file.ts?"), \
                patch("cmux_harness.orchestrator.cmux_api._v2_request") as mock_v2, \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}):
            self.orchestrator.poll_tasks(objective["id"])

        # Verify no keystroke was sent — approval is handled by hooks now
        for call in mock_v2.call_args_list:
            if len(call[0]) >= 1:
                self.assertNotEqual(call[0][0], "surface.send_key")

    def test_poll_tasks_does_not_escalate_via_polling(self):
        """Escalation is now handled by PreToolUse hooks, not polling."""
        task = {"id": "task-1", "status": "executing", "workspaceId": "ws-1", "worktreePath": str(self.project_dir)}
        objective = self._create_objective([task])

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Choose one option"), \
                patch("cmux_harness.orchestrator.cmux_api.cmux_send_to_workspace") as mock_send, \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}):
            self.orchestrator.poll_tasks(objective["id"])

        mock_send.assert_not_called()
        messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "approval"]
        self.assertEqual(len(messages), 0)

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
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "stalled", "reason": "no activity", "elapsed_minutes": 10.0}):
            self.orchestrator.poll_tasks(objective["id"])

        messages = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "alert"]
        self.assertEqual(len(messages), 1)
        self.assertIn("appears stalled", messages[0]["content"])
        self.assertEqual(messages[0]["metadata"]["screen_preview"], "stalled screen")

    def test_poll_tasks_uses_started_at_when_no_progress_seen_yet(self):
        started_at = "2026-04-12T18:41:29+00:00"
        task = {
            "id": "task-1",
            "status": "executing",
            "workspaceId": "ws-1",
            "worktreePath": str(self.project_dir),
            "startedAt": started_at,
        }
        objective = self._create_objective([task])

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="screen"), \
                patch("cmux_harness.orchestrator.monitor.check_progress", return_value={"has_result": False, "has_progress_update": False}), \
                patch("cmux_harness.orchestrator.monitor.check_git_activity", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.assess_stuck_status", return_value={"level": "ok"}) as mock_assess:
            self.orchestrator.poll_tasks(objective["id"])

        task_state = mock_assess.call_args.args[0]
        self.assertEqual(
            task_state["last_progress_at"],
            datetime.fromisoformat(started_at).timestamp(),
        )

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

    def test_poll_tasks_reconciles_stuck_executing_objective_with_failed_task(self):
        tasks = [
            {"id": "task-1", "status": "completed", "workspaceId": None, "worktreePath": str(self.project_dir)},
            {"id": "task-2", "status": "failed", "workspaceId": None, "worktreePath": str(self.project_dir)},
        ]
        objective = self._create_objective(tasks)

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace") as mock_read, \
                patch("cmux_harness.orchestrator.monitor.check_progress") as mock_progress:
            self.orchestrator.poll_tasks(objective["id"])

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")
        mock_read.assert_not_called()
        mock_progress.assert_not_called()
        alerts = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "alert"]
        self.assertTrue(any("Recovered objective state" in msg["content"] for msg in alerts))


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

    def _create_task_files(
        self,
        objective_id,
        task_id,
        result_text="task result",
        spec_text="task spec",
        contract_text=None,
    ):
        objectives.write_task_file(objective_id, task_id, "result.md", result_text)
        objectives.write_task_file(objective_id, task_id, "spec.md", spec_text)
        if contract_text is not None:
            objectives.write_task_file(objective_id, task_id, "contract.md", contract_text)

    def test_build_task_review_prompt_accepts_contract_text(self):
        prompt = self.orchestrator._build_task_review_prompt(
            "task spec",
            "task result",
            "1 file changed",
            "diff --git a/foo b/foo",
            "AC1: saves data",
        )

        self.assertIn("=== CONTRACT ACCEPTANCE CRITERIA ===", prompt)
        self.assertIn("AC1: saves data", prompt)
        self.assertIn("criteria_results", prompt)

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
                    "verdict": "pass",
                    "tier1_build": "skipped",
                    "tier2_maestro": "skipped",
                    "criteria_results": [
                        {
                            "criterion": "Contract is satisfied",
                            "result": "pass",
                            "evidence": "Implementation and diff match the requirement",
                        }
                    ],
                    "issues": [],
                    "recommendation": "Looks good",
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=False), \
                patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch_ready, \
                patch.object(self.orchestrator, "_complete_objective") as mock_complete:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "completed")
        self.assertEqual(updated_task["reviewCycles"], 1)
        self.assertIn("completedAt", updated_task)
        self.assertEqual(
            json.loads(objectives.read_task_file(objective["id"], "task-1", "review.json"))["criteria_results"][0]["result"],
            "pass",
        )
        self.assertTrue(any("review passed" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"])))
        mock_close.assert_called_once_with(objective["id"], "ws-1", "task_completed", task_id="task-1")
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
        self._create_task_files(objective["id"], "task-1", contract_text="AC1: Feature works end-to-end")

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "verdict": "pass",
                    "tier1_build": "skipped",
                    "tier2_maestro": "skipped",
                    "criteria_results": [
                        {
                            "criterion": "Feature works end-to-end",
                            "result": "fail",
                            "evidence": "Only UI wiring is present; no functional backend behavior",
                        }
                    ],
                    "issues": [],
                    "recommendation": "Implement the missing backend behavior",
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.can_retry_review", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.build_review_rework_summary", return_value=(["Fix formatting"], "Clean up code")) as mock_rework_summary, \
                patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-rework", True)) as mock_create, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True) as mock_wait, \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send_prompt:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "executing")
        self.assertEqual(updated_task["reviewCycles"], 1)
        self.assertEqual(updated_task["workspaceId"], "ws-rework")
        mock_close.assert_called_once_with(
            objective["id"],
            "ws-1",
            "task_rework_restart",
            task_id="task-1",
        )
        mock_create.assert_called_once_with(
            "Rework: Needs fixes",
            str(worktree),
            objective_id=objective["id"],
            purpose="rework",
            task_id="task-1",
        )
        mock_wait.assert_called_once_with(
            "ws-rework",
            objective_id=objective["id"],
            purpose="rework",
            task_id="task-1",
        )
        self.assertIn("Feature works end-to-end", mock_rework_summary.call_args.args[0]["issues"][0])
        mock_send_prompt.assert_called_once_with("ws-rework", unittest.mock.ANY)
        self.assertTrue(
            any("sending back for fixes" in msg["content"] for msg in self.orchestrator.get_messages(objective["id"]))
        )

    def test_run_review_skips_maestro_for_non_runtime_contracts(self):
        worktree = self.project_dir / "wt-jira"
        worktree.mkdir()
        task = {
            "id": "task-1",
            "title": "Create Jira ticket",
            "status": "reviewing",
            "workspaceId": "ws-1",
            "worktreePath": str(worktree),
            "reviewCycles": 0,
            "maxReviewCycles": 5,
        }
        objective = self._create_objective([task])
        self._create_task_files(
            objective["id"],
            "task-1",
            result_text="Created IOSDOX-25752 and linked it to the branch.",
            contract_text="""## Acceptance Criteria
1. The Jira ticket exists with the requested metadata and links.

## Build Verification
- Verify the Jira issue exists with the correct title and branch link.

## Functional Test Hints
- Confirm the Jira ticket exists and the referenced links resolve.

## Pass/Fail Threshold
- Fail if the Jira issue is missing, incorrect, or unlinked.
""",
        )

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "verdict": "pass",
                    "tier1_build": "skipped",
                    "criteria_results": [
                        {
                            "criterion": "The Jira ticket exists with the requested metadata and links.",
                            "result": "pass",
                            "evidence": "IOSDOX-25752 was created and linked correctly.",
                        }
                    ],
                    "issues": [],
                    "recommendation": "Looks good",
                }), \
                patch("cmux_harness.orchestrator.evaluator.is_maestro_available", return_value=True), \
                patch("cmux_harness.orchestrator.evaluator.run_tier2_maestro") as mock_maestro, \
                patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch.object(self.orchestrator, "_launch_ready_tasks") as mock_launch_ready, \
                patch.object(self.orchestrator, "_complete_objective") as mock_complete:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "completed")
        self.assertEqual(
            json.loads(objectives.read_task_file(objective["id"], "task-1", "review.json"))["tier2_maestro"],
            "skipped",
        )
        mock_maestro.assert_not_called()
        mock_close.assert_called_once_with(objective["id"], "ws-1", "task_completed", task_id="task-1")
        mock_launch_ready.assert_called_once_with(objective["id"])
        mock_complete.assert_called_once_with(objective["id"])

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
                    "verdict": "fail",
                    "tier1_build": "skipped",
                    "tier2_maestro": "skipped",
                    "criteria_results": [
                        {
                            "criterion": "Feature works end-to-end",
                            "result": "fail",
                            "evidence": "Implementation is still incomplete",
                        }
                    ],
                    "issues": ["Fix formatting"],
                    "recommendation": "Clean up code",
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.can_retry_review", return_value=False), \
                patch("cmux_harness.orchestrator.monitor.build_review_rework_summary", return_value=(["Fix formatting"], "Clean up code")), \
                patch.object(self.orchestrator, "_close_workspace") as mock_close:
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        updated_task = updated["tasks"][0]
        self.assertEqual(updated_task["status"], "failed")
        self.assertEqual(updated_task["reviewCycles"], 5)
        self.assertEqual(updated["status"], "failed")
        mock_close.assert_called_once_with(objective["id"], "ws-1", "task_failed", task_id="task-1")
        alerts = [msg for msg in self.orchestrator.get_messages(objective["id"]) if msg["type"] == "alert"]
        self.assertEqual(len(alerts), 1)
        self.assertIn("Needs your attention", alerts[0]["content"])
        self.assertEqual(alerts[0]["metadata"]["issues"], ["Fix formatting"])

    def test_run_review_marks_objective_failed_when_rework_workspace_creation_fails(self):
        worktree = self.project_dir / "wt-rework-fail"
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
        self._create_task_files(objective["id"], "task-1", contract_text="AC1: Feature works end-to-end")
        (worktree / "result.md").write_text("stale result", encoding="utf-8")
        (worktree / "progress.md").write_text("stale progress", encoding="utf-8")

        mock_git = Mock(returncode=0, stdout=" 1 file changed", stderr="")
        with patch("cmux_harness.orchestrator.subprocess.run", return_value=mock_git), \
                patch("cmux_harness.orchestrator.claude_cli.run_sonnet", return_value={
                    "verdict": "fail",
                    "tier1_build": "skipped",
                    "tier2_maestro": "skipped",
                    "criteria_results": [
                        {
                            "criterion": "Feature works end-to-end",
                            "result": "fail",
                            "evidence": "Implementation is still incomplete",
                        }
                    ],
                    "issues": ["Fix formatting"],
                    "recommendation": "Clean up code",
                }), \
                patch("cmux_harness.orchestrator.monitor.should_trigger_rework", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.can_retry_review", return_value=True), \
                patch("cmux_harness.orchestrator.monitor.build_review_rework_summary", return_value=(["Fix formatting"], "Clean up code")), \
                patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch.object(self.orchestrator, "_create_worker_workspace", return_value=(None, False)):
            self.orchestrator._run_review(objective["id"], "task-1")

        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")
        self.assertEqual(updated["tasks"][0]["status"], "failed")
        self.assertEqual((worktree / "progress.md").read_text(encoding="utf-8"), "")
        self.assertEqual((worktree / "result.md").read_text(encoding="utf-8"), "")
        mock_close.assert_called_once_with(
            objective["id"],
            "ws-1",
            "task_rework_restart",
            task_id="task-1",
        )

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
        self.assertEqual(messages[-1]["type"], "approval_resolved")
        self.assertEqual(messages[-1]["content"], "Task task-1: human approved with 'y' — Claude resumed")

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

    def test_handle_human_input_resumes_inactive_orchestrator_session(self):
        tasks = [
            {"id": "task-1", "title": "First task", "status": "completed", "reviewCycles": 1},
            {"id": "task-2", "title": "Second task", "status": "failed", "reviewCycles": 3},
        ]
        objective = self._create_objective(tasks, status="completed")
        objectives.update_objective(
            objective["id"],
            {
                "orchestratorSessionId": "ws-old",
                "orchestratorSessionActive": False,
            },
        )

        with patch.object(self.orchestrator, "_start_orchestrator_session", return_value="ws-new") as mock_start, \
                patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value=""), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_human_input(objective["id"], "Did all the tasks complete?")

        mock_start.assert_called_once_with(objective["id"])
        mock_send.assert_called_once_with("ws-new", "Did all the tasks complete?")
        mock_thread.assert_called_once()
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[0]["type"], "user")
        self.assertEqual(messages[1]["type"], "system")
        self.assertEqual(messages[1]["content"], "Resuming orchestrator session...")


class TestOrchestratorSessions(unittest.TestCase):

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

    def _create_objective(self, status="executing", tasks=None):
        objective = objectives.create_objective("Session objective", str(self.project_dir))
        objectives.update_objective(objective["id"], {"status": status, "tasks": tasks or []})
        return objective

    def test_start_orchestrator_session_creates_workspace_and_sets_fields(self):
        objective = self._create_objective(
            tasks=[{"id": "task-1", "title": "Inspect repo", "status": "queued", "reviewCycles": 0}]
        )

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-orch", True)) as mock_create, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True) as mock_wait, \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch.object(self.orchestrator, "_capture_orchestrator_response", return_value=""):
            workspace_id = self.orchestrator._start_orchestrator_session(objective["id"])

        self.assertEqual(workspace_id, "ws-orch")
        mock_create.assert_called_once_with(
            "Orchestrator: Session objective",
            objective["worktreePath"],
            objective_id=objective["id"],
            purpose="orchestrator",
        )
        mock_wait.assert_called_once_with("ws-orch", objective_id=objective["id"], purpose="orchestrator")
        prompt = mock_send.call_args.args[1]
        self.assertIn("Objective: Session objective", prompt)
        self.assertIn("Worktree: " + objective["worktreePath"], prompt)
        self.assertIn("- task-1: Inspect repo [queued] (reviewCycles: 0)", prompt)
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["orchestratorSessionId"], "ws-orch")
        self.assertTrue(updated["orchestratorSessionActive"])
        self.assertIn("orchestratorLastActivityAt", updated)
        entries = self.orchestrator.get_debug_entries(objective["id"])
        self.assertTrue(any(entry["event"] == "orchestrator_session_started" for entry in entries))

    def test_capture_orchestrator_response_waits_for_stable_prompt(self):
        objective = self._create_objective()

        with patch(
            "cmux_harness.orchestrator.cmux_api.cmux_read_workspace",
            side_effect=[
                "User prompt\nWorking",
                "User prompt\nFinal answer\n❯",
                "User prompt\nFinal answer\n❯",
            ],
        ), patch("cmux_harness.orchestrator.time.sleep", return_value=None):
            response = self.orchestrator._capture_orchestrator_response(
                objective["id"],
                "ws-orch",
                baseline_screen="User prompt",
                user_message="User prompt",
                initial_delay=0,
                poll_interval=0,
                max_polls=3,
            )

        self.assertEqual(response, "Final answer")
        messages = self.orchestrator.get_messages(objective["id"])
        self.assertEqual(messages[-1]["type"], "assistant")
        self.assertEqual(messages[-1]["content"], "Final answer")
        entries = self.orchestrator.get_debug_entries(objective["id"])
        self.assertTrue(any(entry["event"] == "orchestrator_chat_response" for entry in entries))

    def test_idle_sweep_shuts_down_old_completed_sessions(self):
        objective = self._create_objective(status="completed")
        old_timestamp = (datetime.now(timezone.utc) - timedelta(minutes=61)).isoformat()
        objectives.update_objective(
            objective["id"],
            {
                "orchestratorSessionId": "ws-old",
                "orchestratorSessionActive": True,
                "orchestratorLastActivityAt": old_timestamp,
            },
        )

        with patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch("cmux_harness.orchestrator.time.sleep", side_effect=[None, RuntimeError("stop")]):
            with self.assertRaisesRegex(RuntimeError, "stop"):
                self.orchestrator._idle_sweep()

        mock_close.assert_called_once_with(objective["id"], "ws-old", "idle_timeout")
        updated = objectives.read_objective(objective["id"])
        self.assertFalse(updated["orchestratorSessionActive"])

    def test_idle_sweep_skips_active_execution_sessions(self):
        objective = self._create_objective(status="executing")
        old_timestamp = (datetime.now(timezone.utc) - timedelta(minutes=61)).isoformat()
        objectives.update_objective(
            objective["id"],
            {
                "orchestratorSessionId": "ws-run",
                "orchestratorSessionActive": True,
                "orchestratorLastActivityAt": old_timestamp,
            },
        )

        with patch.object(self.orchestrator, "_close_workspace") as mock_close, \
                patch("cmux_harness.orchestrator.time.sleep", side_effect=[None, RuntimeError("stop")]):
            with self.assertRaisesRegex(RuntimeError, "stop"):
                self.orchestrator._idle_sweep()

        mock_close.assert_not_called()
        updated = objectives.read_objective(objective["id"])
        self.assertTrue(updated["orchestratorSessionActive"])


class TestWorkspaceSessions(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.workspaces_dir = Path(self.tmpdir.name) / "workspaces"
        self.project_dir = Path(self.tmpdir.name) / "project"
        self.project_dir.mkdir()
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.patch_workspaces_dir = patch.object(workspaces, "WORKSPACES_DIR", self.workspaces_dir)
        self.patch_workspaces_dir.start()
        self.addCleanup(self.patch_workspaces_dir.stop)
        self.mock_objectives_run = _patch_objective_git(self)
        self.patch_workspaces_run = patch("cmux_harness.workspaces.subprocess.run")
        self.mock_workspaces_run = self.patch_workspaces_run.start()
        self.mock_workspaces_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        self.addCleanup(self.patch_workspaces_run.stop)
        self.orchestrator = Orchestrator(object())

    def _create_workspace(self, name="Feature Workspace"):
        project = objectives.create_project("Workspace Project", str(self.project_dir), "main")
        return workspaces.create_workspace_session(project["id"], str(self.project_dir), name=name)

    def test_startup_reconciles_stale_workspace_session_and_turns(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="Still working?")
        workspaces.update_workspace_session(
            workspace["id"],
            {
                "cmuxWorkspaceId": "ws-stale",
                "sessionActive": True,
                "status": "active",
            },
        )
        workspaces.update_workspace_turn(
            workspace["id"],
            turn["id"],
            {
                "status": "timed_out",
                "progressSummary": "Still working. This one is taking longer than usual.",
            },
        )

        reconciled = Orchestrator(object())

        del reconciled
        updated_workspace = workspaces.read_workspace_session(workspace["id"])
        updated_turn = workspaces.read_workspace_turn(workspace["id"], turn["id"])
        self.assertEqual(updated_workspace["sessionActive"], False)
        self.assertEqual(updated_workspace["cmuxWorkspaceId"], "")
        self.assertEqual(updated_workspace["status"], "idle")
        self.assertEqual(updated_turn["status"], "failed")
        self.assertIn("Dashboard restarted", updated_turn["lastError"])
        self.assertIsNone(workspaces.get_active_workspace_turn(workspace["id"]))

    def test_startup_reconciles_stale_executing_objective_with_failed_task(self):
        objective = objectives.create_objective("Broken objective", str(self.project_dir))
        objectives.update_objective(
            objective["id"],
            {
                "status": "executing",
                "tasks": [
                    {"id": "task-1", "status": "completed"},
                    {"id": "task-2", "status": "failed"},
                ],
            },
        )

        reconciled = Orchestrator(object())

        del reconciled
        updated = objectives.read_objective(objective["id"])
        self.assertEqual(updated["status"], "failed")

    def test_handle_workspace_input_wraps_message_for_callback_delivery(self):
        workspace = self._create_workspace()
        workspaces.update_workspace_session(
            workspace["id"],
            {
                "cmuxWorkspaceId": "ws-1",
                "sessionActive": True,
                "status": "active",
            },
        )
        self.orchestrator._append_workspace_message(workspace["id"], "assistant", "The branch is up and the push succeeded.")
        self.orchestrator._append_workspace_message(workspace["id"], "user", "What changed in the branch?")

        with patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_workspace_input(workspace["id"], "What's the status?")

        turns = workspaces.list_workspace_turns(workspace["id"])
        self.assertEqual(len(turns), 1)
        turn = turns[0]
        prompt = mock_send.call_args.args[1]
        self.assertIn("Do not answer in the terminal for this turn.", prompt)
        self.assertIn("report_turn.py", prompt)
        self.assertIn(turn["id"], prompt)
        self.assertIn(turn["token"], prompt)
        self.assertNotIn("Recent workspace conversation context follows.", prompt)
        self.assertNotIn("The branch is up and the push succeeded.", prompt)
        self.assertNotIn("What changed in the branch?", prompt)
        self.assertEqual(mock_thread.call_count, 2)
        thread_calls = [call.kwargs for call in mock_thread.call_args_list]
        self.assertEqual(thread_calls[0]["target"], self.orchestrator._watch_workspace_turn)
        self.assertEqual(thread_calls[0]["args"], (workspace["id"], turn["id"]))
        self.assertEqual(thread_calls[1]["target"], self.orchestrator._monitor_workspace_turn_progress)
        self.assertEqual(thread_calls[1]["args"], (workspace["id"], turn["id"], "ws-1"))
        self.assertEqual(thread_calls[1]["kwargs"]["user_message"], "What's the status?")
        messages = self.orchestrator.get_workspace_messages(workspace["id"])
        self.assertEqual(messages[0]["type"], "assistant")
        self.assertEqual(messages[-1]["content"], "What's the status?")

    def test_append_workspace_message_syncs_conversation_context_file(self):
        workspace = self._create_workspace()

        self.orchestrator._append_workspace_message(workspace["id"], "assistant", "The branch is up and the push succeeded.")
        self.orchestrator._append_workspace_message(workspace["id"], "user", "What changed in the branch?")

        context_path = workspaces.workspace_conversation_context_path(workspace["id"])
        self.assertTrue(context_path.exists())
        content = context_path.read_text(encoding="utf-8")
        self.assertIn("# Workspace Conversation Context", content)
        self.assertIn("## Assistant", content)
        self.assertIn("The branch is up and the push succeeded.", content)
        self.assertIn("## User", content)
        self.assertIn("What changed in the branch?", content)

    def test_start_workspace_session_bootstraps_from_conversation_context_file(self):
        workspace = self._create_workspace()
        self.orchestrator._append_workspace_message(workspace["id"], "assistant", "The branch is up and the push succeeded.")
        self.orchestrator._append_workspace_message(workspace["id"], "user", "What changed in the branch?")
        context_path = workspaces.workspace_conversation_context_path(workspace["id"])

        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-start", True)) as mock_create, \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True) as mock_wait, \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch.object(self.orchestrator, "_capture_workspace_like_response", return_value=""):
            workspace_uuid = self.orchestrator.start_workspace_session(workspace["id"])

        self.assertEqual(workspace_uuid, "ws-start")
        mock_create.assert_called_once()
        mock_wait.assert_called_once_with("ws-start", objective_id=workspace["id"], purpose="workspace")
        prompt = mock_send.call_args.args[1]
        self.assertIn("A workspace conversation context file is available for continuity across re-opened sessions.", prompt)
        self.assertIn("Before you answer any live user turn in this session, read this file now:", prompt)
        self.assertIn("Do not claim you lack prior context without first consulting this file.", prompt)
        self.assertIn(str(context_path), prompt)
        self.assertIn("cat " + str(context_path), prompt)
        self.assertIn("Do this silently.", prompt)

    def test_start_workspace_session_combines_bootstrap_and_initial_turn(self):
        workspace = self._create_workspace()
        with patch.object(self.orchestrator, "_create_worker_workspace", return_value=("ws-start", True)), \
                patch.object(self.orchestrator, "_wait_for_repl", return_value=True), \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch.object(self.orchestrator, "_capture_workspace_like_response", return_value="") as mock_capture:
            workspace_uuid = self.orchestrator.start_workspace_session(
                workspace["id"],
                initial_turn_prompt="User message:\nExplain the value we'd get from that.",
            )

        self.assertEqual(workspace_uuid, "ws-start")
        prompt = mock_send.call_args.args[1]
        self.assertIn("Do not answer this message directly.", prompt)
        self.assertIn("Before you do anything else, read the harness startup instruction file at this exact path:", prompt)
        self.assertIn("HARNESS_STARTUP_READ_FAILED", prompt)
        instruction_path = None
        for line in prompt.splitlines():
            if "/runtime/startup-" in line and line.strip().endswith(".md"):
                instruction_path = Path(line.strip())
                break
        self.assertIsNotNone(instruction_path)
        self.assertTrue(instruction_path.exists())
        content = instruction_path.read_text(encoding="utf-8")
        self.assertIn("This bootstrap message is setup only. Do not answer it by itself.", content)
        self.assertIn("A live user turn follows immediately below.", content)
        self.assertIn("User message:\nExplain the value we'd get from that.", content)
        mock_capture.assert_not_called()

    def test_handle_workspace_input_starts_inactive_workspace_with_single_combined_send(self):
        workspace = self._create_workspace()
        with patch.object(self.orchestrator, "start_workspace_session", return_value="ws-start") as mock_start, \
                patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", return_value=True) as mock_send, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_workspace_input(workspace["id"], "Explain the value we'd get from that.")

        self.assertEqual(mock_send.call_count, 0)
        self.assertEqual(mock_start.call_count, 1)
        self.assertEqual(mock_start.call_args.kwargs["initial_turn_prompt"].count("Do not answer in the terminal for this turn."), 1)
        self.assertEqual(mock_thread.call_count, 2)

    def test_handle_workspace_input_reconnects_when_saved_workspace_is_gone(self):
        workspace = self._create_workspace()
        workspaces.update_workspace_session(
            workspace["id"],
            {
                "cmuxWorkspaceId": "ws-stale",
                "sessionActive": True,
                "status": "active",
            },
        )

        with patch("cmux_harness.orchestrator.cmux_api.send_prompt_to_workspace", side_effect=[False, True]) as mock_send, \
                patch.object(self.orchestrator, "start_workspace_session", return_value="ws-fresh") as mock_start, \
                patch("cmux_harness.orchestrator.threading.Thread") as mock_thread:
            self.orchestrator.handle_workspace_input(workspace["id"], "How did the push go?")

        self.assertEqual(mock_send.call_count, 1)
        self.assertEqual(mock_send.call_args_list[0].args[0], "ws-stale")
        mock_start.assert_called_once()
        self.assertEqual(mock_start.call_args.args, (workspace["id"],))
        self.assertEqual(mock_start.call_args.kwargs["initial_turn_prompt"].count("Do not answer in the terminal for this turn."), 1)
        updated_workspace = workspaces.read_workspace_session(workspace["id"])
        self.assertEqual(updated_workspace["sessionActive"], True)
        self.assertEqual(updated_workspace["cmuxWorkspaceId"], "ws-fresh")
        messages = self.orchestrator.get_workspace_messages(workspace["id"])
        self.assertTrue(any(msg["type"] == "system" and "Reconnecting workspace session" in msg["content"] for msg in messages))
        self.assertEqual(mock_thread.call_count, 2)

    def test_finalize_workspace_turn_appends_callback_message(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="Need the TL;DR")

        payload, status = self.orchestrator.finalize_workspace_turn(
            workspace["id"],
            turn["id"],
            turn["token"],
            "TL;DR: branch is ready for final review.",
        )

        self.assertEqual(status, 200)
        self.assertEqual(payload["ok"], True)
        updated_turn = workspaces.read_workspace_turn(workspace["id"], turn["id"])
        self.assertEqual(updated_turn["status"], "completed")
        messages = self.orchestrator.get_workspace_messages(workspace["id"])
        self.assertEqual(messages[-1]["type"], "assistant")
        self.assertEqual(messages[-1]["content"], "TL;DR: branch is ready for final review.")
        self.assertEqual(messages[-1]["metadata"]["delivery"], "callback")

    def test_watch_workspace_turn_marks_timeout_and_appends_alert(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="What changed?")

        # Time sequence: start=0, first poll=6 (past soft_deadline=5), second poll=12 (past hard_deadline=10), post-loop check=12
        with patch("cmux_harness.orchestrator.time.time", side_effect=[0, 0, 6, 6, 12, 12]), \
                patch("cmux_harness.orchestrator.time.sleep", return_value=None):
            self.orchestrator._watch_workspace_turn(workspace["id"], turn["id"], soft_timeout=1, hard_timeout=2, poll_interval=0)

        updated_turn = workspaces.read_workspace_turn(workspace["id"], turn["id"])
        self.assertEqual(updated_turn["status"], "timed_out")
        messages = self.orchestrator.get_workspace_messages(workspace["id"])
        # Soft message first, then hard alert
        self.assertEqual(messages[-2]["type"], "system")
        self.assertIn("Still waiting", messages[-2]["content"])
        self.assertEqual(messages[-1]["type"], "alert")
        self.assertIn("did not arrive through the callback channel", messages[-1]["content"])

    def test_monitor_workspace_turn_progress_updates_turn_summary(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="What is it doing?")

        def _sleep(_seconds):
            workspaces.update_workspace_turn(workspace["id"], turn["id"], {"status": "completed"})

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Mapping salaries...\nReading files\n"), \
                patch("cmux_harness.orchestrator.claude_cli.run_haiku", return_value={
                    "state": "working",
                    "summary": "Inspecting files and mapping the code paths.",
                    "shouldDisplay": True,
                }), \
                patch("cmux_harness.orchestrator.time.sleep", side_effect=_sleep):
            self.orchestrator._monitor_workspace_turn_progress(
                workspace["id"],
                turn["id"],
                "ws-1",
                user_message="What is it doing?",
                initial_delay=0,
                interval=0,
            )

        updated_turn = workspaces.read_workspace_turn(workspace["id"], turn["id"])
        self.assertEqual(updated_turn["progressSummary"], "Inspecting files and mapping the code paths.")
        self.assertEqual(updated_turn["progressState"], "working")
        self.assertEqual(updated_turn["progressSequence"], 1)

    def test_workspace_progress_snapshot_ignores_callback_protocol_text(self):
        snapshot = self.orchestrator._workspace_progress_snapshot(
            "\n".join(
                [
                    "Do not answer in the terminal for this turn.",
                    "When you are ready to answer the user:",
                    "1. Write ONLY the final answer, in Markdown, to this file: /tmp/cmux-turn-123.md",
                    "2. Run this exact command from the shell:",
                    "python3 /tmp/report_turn.py --turn-id 123 --token abc",
                    "",
                    "⏺ Bash(git log --oneline -5 HEAD)",
                    "  abc123 recent commit",
                ]
            ),
            user_message="How did the push go?",
        )

        self.assertEqual(
            snapshot,
            "\n".join(
                [
                    "⏺ Bash(git log --oneline -5 HEAD)",
                    "  abc123 recent commit",
                ]
            ),
        )

    def test_summarize_workspace_progress_uses_heuristic_when_haiku_fails(self):
        with patch("cmux_harness.orchestrator.claude_cli.run_haiku", return_value={
            "error": "Invalid API key · Fix external API key",
            "type": "claude_cli_error",
            "timestamp": "2026-04-08T04:17:22+00:00",
        }):
            result = self.orchestrator._summarize_workspace_progress(
                "⏺ Bash(git log --oneline -5 origin/main)\n  abc123 latest commit\n",
                user_message="How did the push go?",
                previous_summary="",
                elapsed_seconds=40,
                workspace_id="ws-local",
                turn_id="turn-1",
                snapshot_hash="hash-1",
            )

        self.assertEqual(
            result,
            {
                "state": "working",
                "summary": "Checking the remote branch and push status.",
                "shouldDisplay": True,
            },
        )

    def test_monitor_workspace_turn_progress_logs_debug_events(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="What is it doing?")

        def _sleep(_seconds):
            workspaces.update_workspace_turn(workspace["id"], turn["id"], {"status": "completed"})

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="Mapping salaries...\nReading files\n"), \
                patch("cmux_harness.orchestrator.claude_cli.run_haiku", return_value={
                    "state": "working",
                    "summary": "Inspecting files and mapping the code paths.",
                    "shouldDisplay": True,
                }), \
                patch("cmux_harness.orchestrator.time.sleep", side_effect=_sleep), \
                patch("builtins.print") as mock_print:
            self.orchestrator._monitor_workspace_turn_progress(
                workspace["id"],
                turn["id"],
                "ws-1",
                user_message="What is it doing?",
                initial_delay=0,
                interval=0,
            )

        log_lines = [" ".join(str(arg) for arg in call.args) for call in mock_print.call_args_list]
        self.assertTrue(any("[workspace-progress]" in line for line in log_lines))
        self.assertTrue(any("workspace_turn_progress_monitor_started" in line for line in log_lines))
        self.assertTrue(any("workspace_turn_progress_haiku_request" in line for line in log_lines))
        self.assertTrue(any("workspace_turn_progress_haiku_result" in line for line in log_lines))
        self.assertTrue(any("workspace_turn_progress\"" in line for line in log_lines))

    def test_monitor_workspace_turn_progress_uses_fallback_when_haiku_errors(self):
        workspace = self._create_workspace()
        turn = workspaces.create_workspace_turn(workspace["id"], user_message="How did the push go?")

        def _sleep(_seconds):
            workspaces.update_workspace_turn(workspace["id"], turn["id"], {"status": "completed"})

        with patch("cmux_harness.orchestrator.cmux_api.cmux_read_workspace", return_value="⏺ Bash(git log --oneline -5 origin/main)\n  abc123 latest commit\n"), \
                patch("cmux_harness.orchestrator.claude_cli.run_haiku", return_value={
                    "error": "Invalid API key · Fix external API key",
                    "type": "claude_cli_error",
                    "timestamp": "2026-04-08T04:17:22+00:00",
                }), \
                patch("cmux_harness.orchestrator.time.sleep", side_effect=_sleep):
            self.orchestrator._monitor_workspace_turn_progress(
                workspace["id"],
                turn["id"],
                "ws-1",
                user_message="How did the push go?",
                initial_delay=0,
                interval=0,
            )

        updated_turn = workspaces.read_workspace_turn(workspace["id"], turn["id"])
        self.assertEqual(updated_turn["progressSummary"], "Checking the remote branch and push status.")
        self.assertEqual(updated_turn["progressState"], "working")
        self.assertEqual(updated_turn["progressSequence"], 1)


if __name__ == "__main__":
    unittest.main()
