import unittest
from unittest.mock import patch

from cmux_harness.approval import (
    build_approval_prompt,
    classify_approval,
    should_auto_approve,
)


class TestBuildApprovalPrompt(unittest.TestCase):

    def test_prompt_includes_screen_text(self):
        prompt = build_approval_prompt("Allow Write to app.py? (Y/n)")

        self.assertIn("Allow Write to app.py? (Y/n)", prompt)

    def test_prompt_includes_spec_text_when_provided(self):
        prompt = build_approval_prompt("screen text", spec_text="Update tests for parser")

        self.assertIn("Update tests for parser", prompt)

    def test_prompt_works_without_spec_text(self):
        prompt = build_approval_prompt("screen text", spec_text=None)

        self.assertIn("screen text", prompt)
        self.assertNotIn("Task context:\nNone", prompt)

    def test_prompt_mentions_approve_and_escalate(self):
        prompt = build_approval_prompt("screen text")

        self.assertIn("APPROVE", prompt)
        self.assertIn("ESCALATE", prompt)


class TestClassifyApproval(unittest.TestCase):

    @patch("cmux_harness.approval.time.monotonic", side_effect=[10.0, 10.123])
    @patch("cmux_harness.approval.run_haiku")
    def test_valid_approve_dict_returns_approve_with_latency(self, mock_run_haiku, _mock_monotonic):
        mock_run_haiku.return_value = {
            "decision": "APPROVE",
            "reason": "Routine approval prompt",
        }

        result = classify_approval("screen text", spec_text="spec text", timeout=9)

        self.assertEqual(result["decision"], "APPROVE")
        self.assertEqual(result["reason"], "Routine approval prompt")
        self.assertEqual(result["model"], "haiku")
        self.assertEqual(result["latency_ms"], 123)
        mock_run_haiku.assert_called_once()

    @patch("cmux_harness.approval.time.monotonic", side_effect=[20.0, 20.050])
    @patch("cmux_harness.approval.run_haiku")
    def test_valid_escalate_dict_returns_escalate(self, mock_run_haiku, _mock_monotonic):
        mock_run_haiku.return_value = {
            "decision": "ESCALATE",
            "reason": "Needs human judgment",
        }

        result = classify_approval("screen text")

        self.assertEqual(result["decision"], "ESCALATE")
        self.assertEqual(result["reason"], "Needs human judgment")
        self.assertEqual(result["latency_ms"], 50)

    @patch("cmux_harness.approval.time.monotonic", side_effect=[30.0, 30.001])
    @patch("cmux_harness.approval.run_haiku", return_value="plain string response")
    def test_unexpected_string_defaults_to_escalate(self, _mock_run_haiku, _mock_monotonic):
        result = classify_approval("screen text")

        self.assertEqual(result["decision"], "ESCALATE")
        self.assertIn("Unexpected Haiku response format", result["reason"])
        self.assertEqual(result["latency_ms"], 1)

    @patch("cmux_harness.approval.time.monotonic", side_effect=[40.0, 40.010])
    @patch("cmux_harness.approval.run_haiku")
    def test_error_dict_returns_error_decision(self, mock_run_haiku, _mock_monotonic):
        mock_run_haiku.return_value = {
            "error": "claude timed out after 15s",
            "type": "claude_cli_error",
        }

        result = classify_approval("screen text")

        self.assertEqual(result["decision"], "ERROR")
        self.assertEqual(result["reason"], "claude timed out after 15s")
        self.assertEqual(result["latency_ms"], 10)

    @patch("cmux_harness.approval.time.monotonic", side_effect=[50.0, 50.250])
    @patch("cmux_harness.approval.run_haiku", side_effect=RuntimeError("haiku exploded"))
    def test_exception_returns_error_decision(self, _mock_run_haiku, _mock_monotonic):
        result = classify_approval("screen text")

        self.assertEqual(result["decision"], "ERROR")
        self.assertEqual(result["reason"], "haiku exploded")
        self.assertEqual(result["latency_ms"], 250)


class TestShouldAutoApprove(unittest.TestCase):

    def test_approve_returns_true(self):
        self.assertTrue(should_auto_approve({"decision": "APPROVE"}))

    def test_escalate_returns_false(self):
        self.assertFalse(should_auto_approve({"decision": "ESCALATE"}))

    def test_error_returns_false(self):
        self.assertFalse(should_auto_approve({"decision": "ERROR"}))

    def test_unknown_decision_returns_false(self):
        self.assertFalse(should_auto_approve({"decision": "MAYBE"}))


if __name__ == "__main__":
    unittest.main()
