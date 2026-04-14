import json
import unittest
from unittest.mock import MagicMock, patch

from cmux_harness.routes.hooks import (
    handle_pre_tool_use,
    _resolve_context,
    _build_allow_response,
    _build_ask_response,
)


class MockHandler:
    """Minimal handler mock capturing the JSON response."""

    def __init__(self, response_sent=True):
        self.response = None
        self.status = None
        self.response_sent = response_sent

    def _json_response(self, data, status=200):
        self.response = data
        self.status = status
        return self.response_sent


class TestBuildResponses(unittest.TestCase):

    def test_allow_response_format(self):
        resp = _build_allow_response(2, "File write tool")
        self.assertEqual(resp["hookSpecificOutput"]["hookEventName"], "PreToolUse")
        self.assertEqual(resp["hookSpecificOutput"]["permissionDecision"], "allow")
        self.assertIn("Level 2", resp["hookSpecificOutput"]["permissionDecisionReason"])

    def test_ask_response_format(self):
        resp = _build_ask_response(5, "Destructive command")
        self.assertEqual(resp["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertIn("Level 5", resp["hookSpecificOutput"]["permissionDecisionReason"])


class TestHandlePreToolUse(unittest.TestCase):

    def _make_engine(self, threshold=3, objectives=None):
        engine = MagicMock()
        engine.approval_threshold = threshold
        engine.orchestrator._pending_hook_approvals = set()
        engine.orchestrator._append_message = MagicMock()
        engine.orchestrator._log_event = MagicMock()
        return engine

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_read_tool_auto_approved(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "Read", "tool_input": {"file_path": "/src/main.py"}, "cwd": "/tmp"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "allow")
        engine.orchestrator._append_message.assert_not_called()

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_edit_tool_auto_approved(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "Edit", "tool_input": {}, "cwd": "/tmp"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "allow")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_ls_tool_auto_approved(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "LS", "tool_input": {}, "cwd": "/tmp"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "allow")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_destructive_bash_denied(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": "obj-1", "task_id": "task-1", "workspace_id": "ws-1", "spec_text": "Build the app"}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}, "cwd": "/project"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "ask")
        engine.orchestrator._append_message.assert_called_once()
        call_args = engine.orchestrator._append_message.call_args
        self.assertEqual(call_args[0][1], "approval")
        metadata = call_args[1].get("metadata") or call_args[0][3]
        self.assertEqual(metadata["severity_level"], 5)
        self.assertEqual(metadata["tool_name"], "Bash")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_safe_bash_approved(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "Bash", "tool_input": {"command": "npm test"}, "cwd": "/project"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "allow")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_ask_user_question_denied(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": "obj-1", "task_id": "task-1", "workspace_id": "ws-1", "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "AskUserQuestion", "tool_input": {}, "cwd": "/project"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "ask")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_threshold_4_approves_level_4(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine(threshold=4)
        data = {"tool_name": "AskUserQuestion", "tool_input": {}, "cwd": "/tmp"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "allow")

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_no_escalation_message_when_no_objective(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": None, "task_id": None, "workspace_id": None, "spec_text": None}
        handler = MockHandler()
        engine = self._make_engine()
        data = {"tool_name": "AskUserQuestion", "tool_input": {}, "cwd": "/unknown"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "ask")
        # No message appended because objective_id is None
        engine.orchestrator._append_message.assert_not_called()

    @patch("cmux_harness.routes.hooks._resolve_context")
    def test_no_escalation_message_when_ask_response_not_sent(self, mock_resolve):
        mock_resolve.return_value = {"objective_id": "obj-1", "task_id": "task-1", "workspace_id": "ws-1", "spec_text": None}
        handler = MockHandler(response_sent=False)
        engine = self._make_engine()
        data = {"tool_name": "AskUserQuestion", "tool_input": {}, "cwd": "/project"}

        handle_pre_tool_use(handler, data, engine=engine)

        self.assertEqual(handler.response["hookSpecificOutput"]["permissionDecision"], "ask")
        self.assertNotIn("task-1", engine.orchestrator._pending_hook_approvals)
        engine.orchestrator._append_message.assert_not_called()
        engine.orchestrator._log_event.assert_not_called()


class TestResolveContext(unittest.TestCase):

    def test_empty_cwd(self):
        engine = MagicMock()
        result = _resolve_context(engine, "")
        self.assertIsNone(result["objective_id"])

    @patch("cmux_harness.routes.hooks.objectives")
    def test_matches_task_worktree(self, mock_objectives):
        mock_objectives.list_objectives.return_value = [{"id": "obj-1"}]
        mock_objectives.read_objective.return_value = {
            "id": "obj-1",
            "worktreePath": "/tmp/worktree",
            "tasks": [
                {"id": "task-1", "worktreePath": "/tmp/worktree"},
            ],
        }
        mock_objectives.read_task_file.return_value = "Build the feature"

        engine = MagicMock()
        result = _resolve_context(engine, "/tmp/worktree")

        self.assertEqual(result["objective_id"], "obj-1")
        self.assertEqual(result["task_id"], "task-1")
        self.assertEqual(result["spec_text"], "Build the feature")

    @patch("cmux_harness.routes.hooks.objectives")
    def test_no_match_returns_none(self, mock_objectives):
        mock_objectives.list_objectives.return_value = [{"id": "obj-1"}]
        mock_objectives.read_objective.return_value = {
            "id": "obj-1",
            "worktreePath": "/tmp/worktree",
            "tasks": [],
        }

        engine = MagicMock()
        result = _resolve_context(engine, "/some/other/path")

        self.assertIsNone(result["objective_id"])


if __name__ == "__main__":
    unittest.main()
