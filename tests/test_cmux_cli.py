import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import cmux_cli


class TestCmuxCli(unittest.TestCase):
    def test_parse_tree_sessions_returns_terminal_surfaces(self):
        payload = {
            "windows": [{
                "workspaces": [{
                    "uuid": "workspace-1",
                    "ref": "workspace:1",
                    "title": "Ship UI",
                    "index": 3,
                    "current_directory": "/repo",
                    "panes": [{
                        "ref": "pane:1",
                        "surfaces": [
                            {"id": "surface-1", "ref": "surface:1", "type": "terminal", "title": "Codex"},
                            {"id": "surface-web", "type": "browser", "title": "Preview"},
                        ],
                    }],
                }]
            }]
        }

        sessions = cmux_cli.parse_tree_sessions(payload)

        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["workspaceId"], "workspace-1")
        self.assertEqual(sessions[0]["surfaceId"], "surface-1")
        self.assertEqual(sessions[0]["title"], "Ship UI")
        self.assertEqual(sessions[0]["surfaceTitle"], "Codex")
        self.assertEqual(sessions[0]["cwd"], "/repo")

    def test_parse_tree_sessions_infers_cwd_from_cmux_terminal_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            project = home / "Documents" / "Development" / "html-cms"
            project.mkdir(parents=True)
            payload = {
                "windows": [{
                    "workspaces": [{
                        "uuid": "workspace-1",
                        "ref": "workspace:1",
                        "title": "html-cms",
                        "panes": [{
                            "ref": "pane:1",
                            "surfaces": [{
                                "id": "surface-1",
                                "ref": "surface:1",
                                "type": "terminal",
                                "title": "…/Documents/Development/html-cms",
                            }],
                        }],
                    }]
                }]
            }

            with patch("cmux_harness.cmux_cli.Path.home", return_value=home):
                sessions = cmux_cli.parse_tree_sessions(payload)

        self.assertEqual(sessions[0]["cwd"], str(project))

    def test_list_sessions_invokes_project_relative_cli_path(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"windows": [{"workspaces": [{"uuid": "workspace-1", "panes": []}]}]}),
            stderr="",
        )

        with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
            sessions = cmux_cli.CmuxCli(executable="/custom/cmux").list_sessions()

        self.assertEqual(sessions[0]["workspaceId"], "workspace-1")
        self.assertEqual(mock_run.call_args.args[0], ["/custom/cmux", "--id-format", "both", "tree", "--all", "--json"])

    def test_list_sessions_enriches_missing_cwd_from_surface_process(self):
        tree = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({
                "windows": [{
                    "workspaces": [{
                        "uuid": "workspace-1",
                        "ref": "workspace:1",
                        "title": "Worktree",
                        "panes": [{
                            "ref": "pane:1",
                            "surfaces": [{"id": "surface-1", "ref": "surface:1", "type": "terminal", "title": "Worktree"}],
                        }],
                    }]
                }]
            }),
            stderr="",
        )
        top = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="0.0\t1\t1\tprocess\t12345\tsurface:1\tcodex\n",
            stderr="",
        )
        with tempfile.TemporaryDirectory() as tmp, \
                patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.CmuxCli.run", side_effect=[tree, top]), \
                patch("cmux_harness.cmux_cli.process_cwd", return_value=tmp):
            sessions = cmux_cli.CmuxCli(executable="/custom/cmux").list_sessions()

        self.assertEqual(sessions[0]["cwd"], tmp)

    def test_create_session_maps_launch_type_to_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps({"workspace": {"uuid": "workspace-2", "index": 4}}),
                stderr="",
            )
            with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                    patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
                session = cmux_cli.CmuxCli(executable="/custom/cmux").create_session(
                    title="Run Codex",
                    cwd=tmp,
                    launch_type="Codex",
                )

        args = mock_run.call_args.args[0]
        self.assertEqual(session["workspaceId"], "workspace-2")
        self.assertEqual(args[:4], ["/custom/cmux", "--id-format", "both", "new-workspace"])
        self.assertIn("--command", args)
        self.assertIn("codex", args)

    def test_empty_shell_does_not_choose_a_coding_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="{}", stderr="")
            with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                    patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
                cmux_cli.CmuxCli(executable="/custom/cmux").create_session(
                    title="Shell",
                    cwd=tmp,
                    launch_type="Empty shell",
                )

        args = mock_run.call_args_list[0].args[0]
        self.assertEqual(args[:4], ["/custom/cmux", "--id-format", "both", "new-workspace"])
        self.assertNotIn("--command", args)
        self.assertNotIn("codex", args)
        self.assertNotIn("claude", args)
        self.assertNotIn("opencode", args)

    def test_read_session_uses_read_only_scrollback_command(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="terminal text", stderr="")
        with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
            screen = cmux_cli.CmuxCli(executable="/custom/cmux").read_session("workspace-1", "surface-1", lines=50)

        self.assertEqual(screen, "terminal text")
        self.assertEqual(
            mock_run.call_args.args[0],
            ["/custom/cmux", "read-screen", "--scrollback", "--lines", "50", "--workspace", "workspace-1", "--surface", "surface-1"],
        )

    def test_send_text_uses_current_cmux_send_command_shape(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
            result = cmux_cli.CmuxCli(executable="/custom/cmux").send_text("workspace-1", "echo hi", surface_id="surface-1")

        self.assertTrue(result["ok"])
        self.assertEqual(
            mock_run.call_args.args[0],
            ["/custom/cmux", "send", "--workspace", "workspace-1", "--surface", "surface-1", "echo hi"],
        )

    def test_send_key_uses_current_cmux_send_key_command_shape(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.subprocess.run", return_value=completed) as mock_run:
            result = cmux_cli.CmuxCli(executable="/custom/cmux").send_key("workspace-1", "Enter", surface_id="surface-1")

        self.assertTrue(result["ok"])
        self.assertEqual(
            mock_run.call_args.args[0],
            ["/custom/cmux", "send-key", "--workspace", "workspace-1", "--surface", "surface-1", "enter"],
        )

    def test_send_key_falls_back_to_control_sequence_for_extended_terminal_key(self):
        failure = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="unsupported key")
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with patch("cmux_harness.cmux_cli.Path.exists", return_value=True), \
                patch("cmux_harness.cmux_cli.subprocess.run", side_effect=[failure, completed]) as mock_run:
            result = cmux_cli.CmuxCli(executable="/custom/cmux").send_key("workspace-1", "left", surface_id="surface-1")

        self.assertTrue(result["ok"])
        self.assertEqual(
            mock_run.call_args_list[0].args[0],
            ["/custom/cmux", "send-key", "--workspace", "workspace-1", "--surface", "surface-1", "left"],
        )
        self.assertEqual(
            mock_run.call_args_list[1].args[0],
            ["/custom/cmux", "send", "--workspace", "workspace-1", "--surface", "surface-1", "\x1b[D"],
        )


if __name__ == "__main__":
    unittest.main()
