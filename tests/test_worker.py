import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import worker


class TestWorker(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objective_dir = Path(self.tmpdir.name) / "objective-1"
        self.get_objective_dir_patch = patch(
            "cmux_harness.worker.get_objective_dir",
            return_value=self.objective_dir,
        )
        self.get_objective_dir_patch.start()
        self.addCleanup(self.get_objective_dir_patch.stop)

    def test_slugify_normal_text(self):
        self.assertEqual(worker.slugify("Fix Token Refresh Bug"), "fix-token-refresh-bug")

    def test_slugify_removes_special_characters(self):
        self.assertEqual(worker.slugify("Fix @auth/#token!"), "fix-auth-token")

    def test_slugify_collapses_spaces_and_hyphens(self):
        self.assertEqual(worker.slugify("Fix   token---refresh"), "fix-token-refresh")

    def test_slugify_truncates_to_max_len(self):
        self.assertEqual(worker.slugify("abcdefghijklmnopqrstuvwxyz", max_len=10), "abcdefghij")

    def test_slugify_strips_leading_and_trailing_hyphens(self):
        self.assertEqual(worker.slugify("---Fix token refresh---"), "fix-token-refresh")

    def test_slugify_empty_string(self):
        self.assertEqual(worker.slugify(""), "")

    def test_build_task_prompt_mentions_deliverables_and_required_files(self):
        prompt = worker.build_task_prompt("task-1")

        self.assertIn("spec.md", prompt)
        self.assertIn("context.md", prompt)
        self.assertIn("progress.md", prompt)
        self.assertIn("result.md", prompt)
        self.assertIn("CRITICAL RULES", prompt)
        self.assertIn("Implement the deliverables described in spec.md. Focus on the user story.", prompt)
        self.assertNotIn("Scope Boundary", prompt)

    def test_build_rework_prompt_mentions_issues_and_deliverables(self):
        prompt = worker.build_rework_prompt(
            ["Fix the failing unit test", "Update the error handling"],
            "Re-run the targeted tests after the fix.",
        )

        self.assertIn("Fix the failing unit test", prompt)
        self.assertIn("Update the error handling", prompt)
        self.assertIn("Re-run the targeted tests after the fix.", prompt)
        self.assertIn("spec.md", prompt)
        self.assertIn("progress.md", prompt)
        self.assertIn("result.md", prompt)
        self.assertIn("Implement the deliverables described in spec.md. Focus on the user story.", prompt)
        self.assertNotIn("scope boundary", prompt.lower())

    @patch("cmux_harness.worker.subprocess.run")
    def test_create_worktree_constructs_expected_git_command(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        path = worker.create_worktree(
            "/tmp/project",
            "objective-1",
            "task-7",
            "Fix Token Refresh Bug!!!",
            base_branch="develop",
        )

        expected_path = self.objective_dir / "tasks" / "task-7" / "worktree"
        self.assertEqual(path, str(expected_path))
        mock_run.assert_called_once_with(
            [
                "git",
                "-C",
                "/tmp/project",
                "worktree",
                "add",
                str(expected_path),
                "-b",
                "orchestrator/task-7-fix-token-refresh-bug",
                "develop",
            ],
            capture_output=True,
            text=True,
            check=True,
        )

    @patch("cmux_harness.worker.subprocess.run")
    def test_create_worktree_path_is_under_objectives_directory(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        path = worker.create_worktree("/tmp/project", "objective-1", "task-2", "Ship docs")

        self.assertEqual(Path(path).parent, self.objective_dir / "tasks" / "task-2")

    @patch("cmux_harness.worker.subprocess.run")
    def test_create_worktree_raises_worker_error_on_failure(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(
            returncode=1,
            cmd=["git"],
            stderr="branch already exists",
        )

        with self.assertRaises(worker.WorkerError) as ctx:
            worker.create_worktree("/tmp/project", "objective-1", "task-1", "Fix auth")

        self.assertIn("branch already exists", str(ctx.exception))

    @patch("cmux_harness.worker.subprocess.run")
    def test_remove_worktree_constructs_expected_git_command(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        worker.remove_worktree("/tmp/project", "/tmp/worktree")

        mock_run.assert_called_once_with(
            ["git", "-C", "/tmp/project", "worktree", "remove", "/tmp/worktree", "--force"],
            capture_output=True,
            text=True,
            check=True,
        )

    @patch("cmux_harness.worker.subprocess.run")
    def test_remove_worktree_ignores_errors(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(returncode=1, cmd=["git"])

        worker.remove_worktree("/tmp/project", "/tmp/worktree")


if __name__ == "__main__":
    unittest.main()
