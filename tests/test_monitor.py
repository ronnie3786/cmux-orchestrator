import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import monitor


class TestParseCheckpoints(unittest.TestCase):

    def test_parse_standard_format_with_multiple_checkpoints(self):
        progress_text = """
## Checkpoint: Read code
**Status:** Done
**What I did:** Reviewed the auth flow.
**Files touched:** auth.py, tests/test_auth.py

## Checkpoint: Add tests
**Status:** In Progress
**What I did:** Started adding regression coverage.
**Files touched:** tests/test_auth.py
"""

        checkpoints = monitor.parse_checkpoints(progress_text)

        self.assertEqual(len(checkpoints), 2)
        self.assertEqual(checkpoints[0]["name"], "Read code")
        self.assertEqual(checkpoints[0]["status"], "Done")
        self.assertEqual(checkpoints[0]["summary"], "Reviewed the auth flow.")
        self.assertEqual(checkpoints[0]["files"], "auth.py, tests/test_auth.py")
        self.assertEqual(checkpoints[1]["name"], "Add tests")
        self.assertEqual(checkpoints[1]["status"], "In Progress")

    def test_parse_with_missing_optional_fields(self):
        progress_text = """
## Checkpoint: Investigate failure
**Status:** Done
**What I did:** Narrowed the issue to a stale cache check.
"""

        checkpoints = monitor.parse_checkpoints(progress_text)

        self.assertEqual(
            checkpoints,
            [
                {
                    "name": "Investigate failure",
                    "status": "Done",
                    "summary": "Narrowed the issue to a stale cache check.",
                    "files": "",
                }
            ],
        )

    def test_parse_empty_string(self):
        self.assertEqual(monitor.parse_checkpoints(""), [])

    def test_parse_malformed_text(self):
        progress_text = """
Status: Done
What I did: Something useful
No checkpoint headers here
"""

        self.assertEqual(monitor.parse_checkpoints(progress_text), [])


class TestCheckProgress(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objective_dir = Path(self.tmpdir.name) / "objective-1"
        patchers = [
            patch("cmux_harness.monitor.get_objective_dir", return_value=self.objective_dir),
            patch("cmux_harness.objectives.get_objective_dir", return_value=self.objective_dir),
        ]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def _task_dir(self):
        task_dir = self.objective_dir / "tasks" / "task-1"
        task_dir.mkdir(parents=True, exist_ok=True)
        return task_dir

    def test_check_progress_with_progress_file_and_checkpoints(self):
        task_dir = self._task_dir()
        progress_path = task_dir / "progress.md"
        progress_path.write_text(
            """
## Checkpoint: Read code
**Status:** Done
**What I did:** Looked through the handler.
**Files touched:** server.py
""".strip(),
            encoding="utf-8",
        )
        mtime = progress_path.stat().st_mtime

        result = monitor.check_progress("objective-1", "task-1", last_check_ts=mtime - 1)

        self.assertTrue(result["has_progress_update"])
        self.assertEqual(result["checkpoint_count"], 1)
        self.assertEqual(result["checkpoints"][0]["name"], "Read code")
        self.assertEqual(result["progress_mtime"], mtime)
        self.assertFalse(result["has_result"])

    def test_check_progress_without_progress_file(self):
        self._task_dir()

        result = monitor.check_progress("objective-1", "task-1", last_check_ts=0)

        self.assertFalse(result["has_progress_update"])
        self.assertEqual(result["checkpoint_count"], 0)
        self.assertEqual(result["checkpoints"], [])
        self.assertIsNone(result["progress_mtime"])

    def test_check_progress_detects_non_empty_result(self):
        task_dir = self._task_dir()
        (task_dir / "result.md").write_text("Finished the task.\n", encoding="utf-8")

        result = monitor.check_progress("objective-1", "task-1", last_check_ts=0)

        self.assertTrue(result["has_result"])


class TestCheckGitActivity(unittest.TestCase):

    @patch("cmux_harness.monitor.subprocess.run")
    def test_check_git_activity_returns_true_when_commits_found(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="abc123 Fix bug\n",
            stderr="",
        )

        result = monitor.check_git_activity("/tmp/worktree", 1712000000.0)

        self.assertTrue(result)
        self.assertIn("--since=", mock_run.call_args.args[0][5])

    @patch("cmux_harness.monitor.subprocess.run")
    def test_check_git_activity_returns_false_when_no_commits_found(self, mock_run):
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

        self.assertFalse(monitor.check_git_activity("/tmp/worktree", 1712000000.0))

    @patch("cmux_harness.monitor.subprocess.run")
    def test_check_git_activity_returns_false_on_error(self, mock_run):
        mock_run.side_effect = subprocess.CalledProcessError(returncode=1, cmd=["git"])

        self.assertFalse(monitor.check_git_activity("/tmp/worktree", 1712000000.0))


class TestAssessStuckStatus(unittest.TestCase):

    def _task_state(self, **overrides):
        task_state = {
            "task_id": "task-1",
            "status": "executing",
            "last_progress_at": 1000.0,
            "has_git_activity": False,
            "has_terminal_activity": False,
            "now": 1000.0,
        }
        task_state.update(overrides)
        return task_state

    def test_elapsed_under_five_minutes_is_ok(self):
        result = monitor.assess_stuck_status(self._task_state(now=1000.0 + 4 * 60))

        self.assertEqual(result["level"], "ok")

    def test_elapsed_six_minutes_is_monitoring(self):
        result = monitor.assess_stuck_status(self._task_state(now=1000.0 + 6 * 60))

        self.assertEqual(result["level"], "monitoring")

    def test_elapsed_eight_minutes_with_git_activity_is_ok(self):
        result = monitor.assess_stuck_status(
            self._task_state(now=1000.0 + 8 * 60, has_git_activity=True)
        )

        self.assertEqual(result["level"], "ok")

    def test_elapsed_eight_minutes_with_terminal_activity_is_amber(self):
        result = monitor.assess_stuck_status(
            self._task_state(now=1000.0 + 8 * 60, has_terminal_activity=True)
        )

        self.assertEqual(result["level"], "amber")

    def test_elapsed_eight_minutes_without_activity_is_stalled(self):
        result = monitor.assess_stuck_status(self._task_state(now=1000.0 + 8 * 60))

        self.assertEqual(result["level"], "stalled")

    def test_non_executing_task_is_ok(self):
        result = monitor.assess_stuck_status(self._task_state(status="reviewing", now=1000.0 + 20 * 60))

        self.assertEqual(result["level"], "ok")

    def test_missing_last_progress_is_ok(self):
        result = monitor.assess_stuck_status(self._task_state(last_progress_at=None, now=1000.0 + 20 * 60))

        self.assertEqual(result["level"], "ok")


class TestReviewReworkHelpers(unittest.TestCase):

    def test_should_trigger_rework_for_non_empty_issues(self):
        self.assertTrue(monitor.should_trigger_rework({"issues": ["Fix failing test"]}))

    def test_should_trigger_rework_for_low_confidence(self):
        self.assertTrue(monitor.should_trigger_rework({"issues": [], "confidence": "low"}))

    def test_should_trigger_rework_for_not_ready_for_pr(self):
        self.assertTrue(monitor.should_trigger_rework({"issues": [], "readyForPR": False}))

    def test_should_trigger_rework_for_clean_review(self):
        self.assertFalse(
            monitor.should_trigger_rework(
                {"issues": [], "confidence": "high", "readyForPR": True}
            )
        )

    def test_should_trigger_rework_for_empty_review_dict(self):
        self.assertFalse(monitor.should_trigger_rework({}))

    def test_can_retry_review_when_under_limit(self):
        self.assertTrue(monitor.can_retry_review({"reviewCycles": 0, "maxReviewCycles": 5}))
        self.assertTrue(monitor.can_retry_review({"reviewCycles": 4, "maxReviewCycles": 5}))

    def test_can_retry_review_when_at_limit(self):
        self.assertFalse(monitor.can_retry_review({"reviewCycles": 5, "maxReviewCycles": 5}))
        self.assertFalse(monitor.can_retry_review({"reviewCycles": 5}))

    def test_build_review_rework_summary_with_issues_and_recommendation(self):
        issues, recommendation = monitor.build_review_rework_summary(
            {
                "issues": ["Fix the retry path", "Add test coverage"],
                "recommendation": "Patch the bug and rerun targeted tests",
            }
        )

        self.assertEqual(issues, ["Fix the retry path", "Add test coverage"])
        self.assertEqual(recommendation, "Patch the bug and rerun targeted tests")

    def test_build_review_rework_summary_with_empty_issues(self):
        issues, recommendation = monitor.build_review_rework_summary({"issues": [], "confidence": "low"})

        self.assertEqual(issues, ["Review flagged concerns but no specific issues listed"])
        self.assertEqual(recommendation, "Address the identified issues")

    def test_build_review_rework_summary_without_recommendation(self):
        issues, recommendation = monitor.build_review_rework_summary({"issues": ["Fix formatting"]})

        self.assertEqual(issues, ["Fix formatting"])
        self.assertEqual(recommendation, "Address the identified issues")


if __name__ == "__main__":
    unittest.main()
