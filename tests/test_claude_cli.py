import subprocess
import unittest
from unittest.mock import patch

from cmux_harness import claude_cli


class TestClaudeCli(unittest.TestCase):

    @patch("cmux_harness.claude_cli.shutil.which", return_value="claude")
    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_claude_print_returns_stdout(self, mock_run, _mock_which):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["claude", "--print", "-p", "hello"],
            returncode=0,
            stdout="result\n",
            stderr="",
        )

        result = claude_cli.run_claude_print("hello", model="haiku", timeout=12)

        self.assertEqual(result, "result")
        mock_run.assert_called_once_with(
            ["claude", "--print", "--model", "haiku", "-p", "hello"],
            capture_output=True,
            text=True,
            timeout=12,
            check=True,
        )

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_haiku_handles_timeout(self, mock_run):
        mock_run.side_effect = subprocess.TimeoutExpired(cmd=["claude"], timeout=30)

        result = claude_cli.run_haiku("hello", timeout=30)

        self.assertEqual(result["type"], "claude_cli_error")
        self.assertIn("timed out", result["error"])

    @patch("cmux_harness.claude_cli.shutil.which", return_value="claude")
    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_haiku_retries_without_model_on_external_api_key_error(self, mock_run, _mock_which):
        mock_run.side_effect = [
            subprocess.CalledProcessError(
                returncode=2,
                cmd=["claude", "--print", "--model", "haiku", "-p", "hello"],
                stderr="Invalid API key · Fix external API key",
            ),
            subprocess.CompletedProcess(
                args=["claude", "--print", "-p", "hello"],
                returncode=0,
                stdout='{"ok": true}',
                stderr="",
            ),
        ]

        result = claude_cli.run_haiku("hello", timeout=30)

        self.assertEqual(result, {"ok": True})
        self.assertEqual(mock_run.call_count, 2)
        self.assertEqual(mock_run.call_args_list[0].args[0], ["claude", "--print", "--model", "haiku", "-p", "hello"])
        self.assertEqual(mock_run.call_args_list[1].args[0], ["claude", "--print", "-p", "hello"])

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_sonnet_parses_clean_json(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["claude", "--print", "-p", "hello"],
            returncode=0,
            stdout='{"ok": true}',
            stderr="",
        )

        result = claude_cli.run_sonnet("hello")

        self.assertEqual(result, {"ok": True})

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_sonnet_parses_markdown_fenced_json(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["claude", "--print", "-p", "hello"],
            returncode=0,
            stdout='```json\n{"ok": true}\n```',
            stderr="",
        )

        result = claude_cli.run_sonnet("hello")

        self.assertEqual(result, {"ok": True})

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_sonnet_parses_json_with_leading_text(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=["claude", "--print", "-p", "hello"],
            returncode=0,
            stdout='Here is the result:\n{"ok": true}',
            stderr="",
        )

        result = claude_cli.run_sonnet("hello")

        self.assertEqual(result, {"ok": True})

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_sonnet_returns_error_dict_for_called_process_error(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(
            returncode=2,
            cmd=["claude", "--print"],
            stderr="bad exit",
        )

        result = claude_cli.run_sonnet("hello")

        self.assertEqual(result["type"], "claude_cli_error")
        self.assertEqual(result["error"], "bad exit")

    @patch("cmux_harness.claude_cli.subprocess.run")
    def test_run_claude_print_raises_on_called_process_error(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(
            returncode=2,
            cmd=["claude", "--print"],
            stderr="bad exit",
        )

        with self.assertRaises(claude_cli.ClaudeCliError):
            claude_cli.run_claude_print("hello")


if __name__ == "__main__":
    unittest.main()
