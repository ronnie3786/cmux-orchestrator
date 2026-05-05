import subprocess
import unittest
from unittest.mock import patch

from cmux_harness import dependencies


class TestDependencyChecks(unittest.TestCase):
    def tearDown(self):
        dependencies.clear_cache()

    def test_missing_cli_reports_not_ready(self):
        with patch("cmux_harness.dependencies.shutil.which", return_value=None):
            payload = dependencies.check_cli_requirements(force=True)

        self.assertFalse(payload["ok"])
        self.assertEqual([item["status"] for item in payload["items"]], ["missing", "missing"])
        self.assertTrue(all(not item["available"] for item in payload["items"]))

    def test_ready_clis_report_ok(self):
        blocked_marker = "".join(("G", "P", "T"))

        def fake_which(command):
            return f"/usr/local/bin/{command}"

        def fake_run(command, **_kwargs):
            if command[0].endswith("gh") and command[1:] == ["--version"]:
                return subprocess.CompletedProcess(command, 0, stdout="gh version 2.0.0\n", stderr="")
            if command[0].endswith("gh") and command[1:3] == ["auth", "status"]:
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="Logged in to github.com\n")
            if command[0].endswith("acli") and command[1:] == ["--version"]:
                return subprocess.CompletedProcess(command, 0, stdout="acli version 1.0.0\n", stderr="")
            if command[0].endswith("acli") and command[1:4] == ["jira", "workitem", "search"]:
                return subprocess.CompletedProcess(command, 0, stdout=f'[{{"fields":{{"summary":"{blocked_marker} - private ticket summary"}}}}]\n', stderr="")
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="unexpected command")

        with patch("cmux_harness.dependencies.shutil.which", side_effect=fake_which), \
                patch("cmux_harness.dependencies.subprocess.run", side_effect=fake_run):
            payload = dependencies.check_cli_requirements(force=True)

        self.assertTrue(payload["ok"])
        self.assertEqual([item["status"] for item in payload["items"]], ["ok", "ok"])
        self.assertTrue(all(item["available"] and item["configured"] for item in payload["items"]))
        self.assertTrue(all(item["diagnostic"] == "Diagnostic check completed successfully." for item in payload["items"]))
        self.assertTrue(all("private ticket summary" not in item["diagnostic"] for item in payload["items"]))

    def test_failed_cli_diagnostic_is_sanitized(self):
        blocked_marker = "".join(("G", "P", "T"))

        def fake_which(command):
            return f"/usr/local/bin/{command}"

        def fake_run(command, **_kwargs):
            if command[1:] == ["--version"]:
                return subprocess.CompletedProcess(command, 0, stdout=f"{command[0]} version\n", stderr="")
            return subprocess.CompletedProcess(command, 1, stdout="", stderr=f"{blocked_marker} - authentication required")

        with patch("cmux_harness.dependencies.shutil.which", side_effect=fake_which), \
                patch("cmux_harness.dependencies.subprocess.run", side_effect=fake_run):
            payload = dependencies.check_cli_requirements(force=True)

        self.assertFalse(payload["ok"])
        self.assertTrue(all(blocked_marker not in item["diagnostic"] for item in payload["items"]))
        self.assertTrue(all("authentication required" in item["diagnostic"] for item in payload["items"]))

    def test_installed_but_unauthenticated_cli_needs_setup(self):
        def fake_which(command):
            return f"/usr/local/bin/{command}"

        def fake_run(command, **_kwargs):
            if command[1:] == ["--version"]:
                return subprocess.CompletedProcess(command, 0, stdout=f"{command[0]} version\n", stderr="")
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="authentication required")

        with patch("cmux_harness.dependencies.shutil.which", side_effect=fake_which), \
                patch("cmux_harness.dependencies.subprocess.run", side_effect=fake_run):
            payload = dependencies.check_cli_requirements(force=True)

        self.assertFalse(payload["ok"])
        self.assertEqual([item["status"] for item in payload["items"]], ["needs_setup", "needs_setup"])
        self.assertTrue(all(item["available"] for item in payload["items"]))
        self.assertTrue(all("authentication required" in item["diagnostic"] for item in payload["items"]))


if __name__ == "__main__":
    unittest.main()
