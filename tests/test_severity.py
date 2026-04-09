import unittest
from unittest.mock import patch

from cmux_harness.severity import (
    classify_tool_severity,
    should_auto_approve_level,
    _bash_is_destructive,
    _is_safe_mcp_tool,
)


class TestToolSeverityLevels(unittest.TestCase):

    def test_level_1_read_tools(self):
        for tool in ("Read", "Glob", "Grep", "LSP", "ListDir", "Search", "TodoRead"):
            result = classify_tool_severity(tool)
            self.assertEqual(result["level"], 1, f"{tool} should be level 1")
            self.assertEqual(result["decision"], "allow")
            self.assertIsNone(result["model"])

    def test_level_2_write_tools(self):
        for tool in ("Edit", "Write", "MultiEdit", "NotebookEdit", "TodoWrite"):
            result = classify_tool_severity(tool)
            self.assertEqual(result["level"], 2, f"{tool} should be level 2")
            self.assertEqual(result["decision"], "allow")

    def test_level_3_web_tools(self):
        for tool in ("WebFetch", "WebSearch"):
            result = classify_tool_severity(tool)
            self.assertEqual(result["level"], 3, f"{tool} should be level 3")
            self.assertEqual(result["decision"], "allow")

    def test_level_4_judgment_tools(self):
        for tool in ("AskUserQuestion", "Agent", "TaskCreate"):
            result = classify_tool_severity(tool)
            self.assertEqual(result["level"], 4, f"{tool} should be level 4")
            self.assertEqual(result["decision"], "ask")


class TestBashClassification(unittest.TestCase):

    def test_safe_bash_is_level_2(self):
        result = classify_tool_severity("Bash", {"command": "npm test"})
        self.assertEqual(result["level"], 2)
        self.assertEqual(result["decision"], "allow")

    def test_ls_is_level_2(self):
        result = classify_tool_severity("Bash", {"command": "ls -la"})
        self.assertEqual(result["level"], 2)

    def test_rm_rf_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": "rm -rf /tmp/test"})
        self.assertEqual(result["level"], 5)
        self.assertEqual(result["decision"], "ask")

    def test_git_force_push_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": "git push origin main --force"})
        self.assertEqual(result["level"], 5)

    def test_git_push_f_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": "git push -f origin main"})
        self.assertEqual(result["level"], 5)

    def test_git_reset_hard_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": "git reset --hard HEAD~1"})
        self.assertEqual(result["level"], 5)

    def test_drop_table_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": 'psql -c "DROP TABLE users"'})
        self.assertEqual(result["level"], 5)

    def test_delete_from_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": 'psql -c "DELETE FROM users"'})
        self.assertEqual(result["level"], 5)

    def test_npm_publish_is_level_5(self):
        result = classify_tool_severity("Bash", {"command": "npm publish"})
        self.assertEqual(result["level"], 5)

    def test_empty_command_is_level_2(self):
        result = classify_tool_severity("Bash", {"command": ""})
        self.assertEqual(result["level"], 2)

    def test_missing_command_key_is_level_2(self):
        result = classify_tool_severity("Bash", {})
        self.assertEqual(result["level"], 2)


class TestDestructivePatterns(unittest.TestCase):

    def test_rm_f(self):
        self.assertTrue(_bash_is_destructive("rm -f important.txt"))

    def test_rm_rf(self):
        self.assertTrue(_bash_is_destructive("rm -rf /"))

    def test_git_clean_f(self):
        self.assertTrue(_bash_is_destructive("git clean -f"))

    def test_chmod_777(self):
        self.assertTrue(_bash_is_destructive("chmod 777 /etc/passwd"))

    def test_safe_git_push(self):
        self.assertFalse(_bash_is_destructive("git push origin feature-branch"))

    def test_safe_rm(self):
        self.assertFalse(_bash_is_destructive("rm file.txt"))

    def test_safe_cat(self):
        self.assertFalse(_bash_is_destructive("cat /etc/hosts"))


class TestMcpToolClassification(unittest.TestCase):

    def test_known_safe_jira_mcp(self):
        result = classify_tool_severity("mcp__atlassian__jira_get_issue", {})
        self.assertEqual(result["level"], 3)
        self.assertEqual(result["decision"], "allow")

    def test_known_safe_github_mcp(self):
        result = classify_tool_severity("mcp__github__get_pr", {})
        self.assertEqual(result["level"], 3)

    def test_known_safe_slack_mcp(self):
        result = classify_tool_severity("mcp__slack__read_channel", {})
        self.assertEqual(result["level"], 3)

    def test_safe_mcp_helper(self):
        self.assertTrue(_is_safe_mcp_tool("mcp__plugin_slack_slack__slack_search_users"))
        self.assertTrue(_is_safe_mcp_tool("mcp__github__list_prs"))
        self.assertTrue(_is_safe_mcp_tool("mcp__figma__get_screenshot"))
        self.assertFalse(_is_safe_mcp_tool("mcp__unknown_service__do_thing"))

    @patch("cmux_harness.severity.run_haiku")
    def test_unknown_mcp_goes_to_haiku(self, mock_haiku):
        mock_haiku.return_value = {"level": 4, "reason": "Unknown external service"}
        result = classify_tool_severity("mcp__unknown__dangerous_tool", {})
        self.assertEqual(result["level"], 4)
        mock_haiku.assert_called_once()


class TestHaikuFallback(unittest.TestCase):

    @patch("cmux_harness.severity.run_haiku")
    def test_haiku_returns_valid_level(self, mock_haiku):
        mock_haiku.return_value = {"level": 3, "reason": "Safe API call"}
        result = classify_tool_severity("UnknownTool", {"arg": "val"})
        self.assertEqual(result["level"], 3)
        self.assertEqual(result["decision"], "allow")
        self.assertEqual(result["model"], "haiku")

    @patch("cmux_harness.severity.run_haiku")
    def test_haiku_returns_high_level(self, mock_haiku):
        mock_haiku.return_value = {"level": 5, "reason": "Very dangerous"}
        result = classify_tool_severity("UnknownTool", {"arg": "val"})
        self.assertEqual(result["level"], 5)
        self.assertEqual(result["decision"], "ask")

    @patch("cmux_harness.severity.run_haiku", side_effect=Exception("network error"))
    def test_haiku_exception_defaults_to_level_5(self, _mock_haiku):
        result = classify_tool_severity("UnknownTool", {})
        self.assertEqual(result["level"], 5)
        self.assertEqual(result["decision"], "ask")
        self.assertIn("Haiku error", result["reason"])

    @patch("cmux_harness.severity.run_haiku", return_value="not a dict")
    def test_haiku_unexpected_format_defaults_to_level_5(self, _mock_haiku):
        result = classify_tool_severity("UnknownTool", {})
        self.assertEqual(result["level"], 5)
        self.assertEqual(result["decision"], "ask")

    @patch("cmux_harness.severity.run_haiku")
    def test_haiku_error_dict_defaults_to_level_5(self, mock_haiku):
        mock_haiku.return_value = {"error": "timeout", "type": "cli_error"}
        result = classify_tool_severity("UnknownTool", {})
        self.assertEqual(result["level"], 5)

    @patch("cmux_harness.severity.run_haiku")
    def test_haiku_invalid_level_defaults_to_level_5(self, mock_haiku):
        mock_haiku.return_value = {"level": 99, "reason": "out of range"}
        result = classify_tool_severity("UnknownTool", {})
        self.assertEqual(result["level"], 5)


class TestShouldAutoApproveLevel(unittest.TestCase):

    def test_level_1_at_threshold_3(self):
        self.assertTrue(should_auto_approve_level(1, threshold=3))

    def test_level_3_at_threshold_3(self):
        self.assertTrue(should_auto_approve_level(3, threshold=3))

    def test_level_4_at_threshold_3(self):
        self.assertFalse(should_auto_approve_level(4, threshold=3))

    def test_level_5_at_threshold_3(self):
        self.assertFalse(should_auto_approve_level(5, threshold=3))

    def test_custom_threshold_4(self):
        self.assertTrue(should_auto_approve_level(4, threshold=4))
        self.assertFalse(should_auto_approve_level(5, threshold=4))

    def test_threshold_1_only_reads_approved(self):
        self.assertTrue(should_auto_approve_level(1, threshold=1))
        self.assertFalse(should_auto_approve_level(2, threshold=1))


if __name__ == "__main__":
    unittest.main()
