import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import opencode_integration


class TestOpenCodeIntegration(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)
        self.plugin_path = self.root / ".config/opencode/plugins/cmux-feed.js"
        self.cmux_path = self.root / "cmux"
        self.cmux_path.write_text("#!/bin/sh\n", encoding="utf-8")
        self.cmux_path.chmod(0o755)

    def test_status_detects_feed_marker_and_usable_cmux(self):
        self.plugin_path.parent.mkdir(parents=True)
        self.plugin_path.write_text(
            "// cmux-feed-plugin-marker v1\nexport const CmuxFeed = {}\n",
            encoding="utf-8",
        )

        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "environment"),
                ):
            status = opencode_integration.integration_status()

        self.assertTrue(status["ok"])
        self.assertTrue(status["installed"])
        self.assertTrue(status["pluginExists"])
        self.assertTrue(status["cmuxAvailable"])
        self.assertEqual(status["status"], "ready")
        self.assertEqual(status["cmuxSource"], "environment")

    def test_status_distinguishes_unmarked_plugin(self):
        self.plugin_path.parent.mkdir(parents=True)
        self.plugin_path.write_text("export const unrelatedPlugin = {}\n", encoding="utf-8")

        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "path"),
                ):
            status = opencode_integration.integration_status()

        self.assertFalse(status["installed"])
        self.assertTrue(status["pluginExists"])
        self.assertEqual(status["status"], "needs_install")

    def test_executable_resolution_prefers_environment_then_application_then_path(self):
        application_path = self.root / "CmuxApplication"
        application_path.write_text("#!/bin/sh\n", encoding="utf-8")
        application_path.chmod(0o755)
        path_cmux = self.root / "path-cmux"
        path_cmux.write_text("#!/bin/sh\n", encoding="utf-8")
        path_cmux.chmod(0o755)

        resolved, source = opencode_integration._find_cmux_executable(
            environ={"CMUX_CLI_PATH": str(self.cmux_path)},
            application_path=application_path,
            which=lambda _command: str(path_cmux),
        )
        self.assertEqual((resolved, source), (str(self.cmux_path), "environment"))

        self.cmux_path.chmod(0o644)
        resolved, source = opencode_integration._find_cmux_executable(
            environ={"CMUX_CLI_PATH": str(self.cmux_path)},
            application_path=application_path,
            which=lambda _command: str(path_cmux),
        )
        self.assertEqual((resolved, source), (str(application_path), "application"))

        application_path.chmod(0o644)
        resolved, source = opencode_integration._find_cmux_executable(
            environ={"CMUX_CLI_PATH": str(self.cmux_path)},
            application_path=application_path,
            which=lambda _command: str(path_cmux),
        )
        self.assertEqual((resolved, source), (str(path_cmux), "path"))

    def test_install_runs_exact_noninteractive_cmux_command_and_verifies_marker(self):
        def fake_run(command, **kwargs):
            self.plugin_path.parent.mkdir(parents=True, exist_ok=True)
            self.plugin_path.write_text("// cmux-feed-plugin-marker v1\n", encoding="utf-8")
            return subprocess.CompletedProcess(command, 0, stdout="installed\n", stderr="")

        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "environment"),
                ), \
                patch.object(opencode_integration.subprocess, "run", side_effect=fake_run) as mock_run:
            result = opencode_integration.install_integration()

        self.assertTrue(result["ok"])
        self.assertTrue(result["installed"])
        self.assertTrue(result["changed"])
        self.assertTrue(result["needsRestart"])
        mock_run.assert_called_once_with(
            [str(self.cmux_path), "hooks", "opencode", "install", "--yes"],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_install_is_idempotent_when_marker_is_already_present(self):
        self.plugin_path.parent.mkdir(parents=True)
        self.plugin_path.write_text("// cmux-feed-plugin-marker v1\n", encoding="utf-8")

        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "application"),
                ), \
                patch.object(opencode_integration.subprocess, "run") as mock_run:
            result = opencode_integration.install_integration()

        self.assertTrue(result["ok"])
        self.assertTrue(result["installed"])
        self.assertFalse(result["changed"])
        mock_run.assert_not_called()

    def test_install_does_not_spawn_when_cmux_is_unavailable(self):
        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(opencode_integration, "_find_cmux_executable", return_value=("", "")), \
                patch.object(opencode_integration.subprocess, "run") as mock_run:
            result = opencode_integration.install_integration()

        self.assertFalse(result["ok"])
        self.assertEqual(result["errorCode"], "cmux_unavailable")
        mock_run.assert_not_called()

    def test_install_reports_nonzero_exit_without_claiming_success(self):
        completed = subprocess.CompletedProcess(
            [str(self.cmux_path)],
            1,
            stdout="",
            stderr="permission denied",
        )
        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "path"),
                ), \
                patch.object(opencode_integration.subprocess, "run", return_value=completed):
            result = opencode_integration.install_integration()

        self.assertFalse(result["ok"])
        self.assertFalse(result["installed"])
        self.assertEqual(result["errorCode"], "install_failed")
        self.assertIn("permission denied", result["diagnostic"])

    def test_install_reports_timeout(self):
        timeout = subprocess.TimeoutExpired([str(self.cmux_path)], timeout=20, stderr="too slow")
        with patch.object(opencode_integration, "_opencode_plugin_path", return_value=self.plugin_path), \
                patch.object(
                    opencode_integration,
                    "_find_cmux_executable",
                    return_value=(str(self.cmux_path), "path"),
                ), \
                patch.object(opencode_integration.subprocess, "run", side_effect=timeout):
            result = opencode_integration.install_integration()

        self.assertFalse(result["ok"])
        self.assertEqual(result["errorCode"], "install_timeout")


if __name__ == "__main__":
    unittest.main()
