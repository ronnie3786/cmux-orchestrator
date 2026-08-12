import base64
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness import attachments, workspace_tools


class WorkspaceToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self._git("init", "-q")
        self._git("config", "user.email", "herdr@example.test")
        self._git("config", "user.name", "Herdr Test")
        (self.root / "tracked.txt").write_text("original\n", encoding="utf-8")
        self._git("add", "--", "tracked.txt")
        self._git("commit", "-qm", "initial commit")

    def _git(self, *args):
        subprocess.run(
            ["git", "-C", str(self.root), *args],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_workspace_root_prefers_checkout_then_falls_back_to_focused_pane(self):
        pane_root = self.root / "Sources"
        pane_root.mkdir()
        workspace = {
            "worktree": {"checkout_path": str(self.root)},
            "panes": [{"focused": True, "foreground_cwd": str(pane_root)}],
        }
        self.assertEqual(workspace_tools.workspace_root(workspace), self.root.resolve())

        workspace["worktree"]["checkout_path"] = str(self.root / "missing")
        self.assertEqual(workspace_tools.workspace_root(workspace), pane_root.resolve())

    def test_git_status_diff_stage_and_unstage_cover_all_sections(self):
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        (self.root / "staged.txt").write_text("staged\n", encoding="utf-8")
        (self.root / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        self._git("add", "--", "staged.txt")

        status_payload = workspace_tools.git_status(self.root)
        self.assertEqual(status_payload["root_path"], str(self.root.resolve()))
        self.assertEqual(status_payload["unstaged"], [{"status": "M", "file": "tracked.txt"}])
        self.assertEqual(status_payload["staged"], [{"status": "A", "file": "staged.txt"}])
        self.assertEqual(status_payload["untracked"], ["untracked.txt"])
        self.assertEqual(status_payload["commits"][0]["message"], "initial commit")

        unstaged = workspace_tools.git_diff(self.root, "tracked.txt", "unstaged")
        staged = workspace_tools.git_diff(self.root, "staged.txt", "staged")
        untracked = workspace_tools.git_diff(self.root, "untracked.txt", "untracked")
        self.assertIn("+changed", unstaged["diff"])
        self.assertIn("+staged", staged["diff"])
        self.assertIn("+untracked", untracked["diff"])

        self.assertEqual(workspace_tools.git_stage(self.root, "untracked.txt"), "untracked.txt")
        self.assertIn("untracked.txt", [item["file"] for item in workspace_tools.git_status(self.root)["staged"]])
        self.assertEqual(workspace_tools.git_unstage(self.root, "untracked.txt"), "untracked.txt")
        self.assertIn("untracked.txt", workspace_tools.git_status(self.root)["untracked"])

    def test_git_paths_reject_absolute_traversal_and_symlink_escape(self):
        outside = Path(self.temporary.name) / "secret.txt"
        outside.write_text("secret", encoding="utf-8")
        (self.root / "outside-link").symlink_to(outside)

        for value in ("../secret.txt", str(outside), "outside-link"):
            with self.subTest(value=value), self.assertRaises(workspace_tools.WorkspaceToolError) as context:
                workspace_tools.git_diff(self.root, value, "untracked")
            self.assertEqual(context.exception.code, "invalid_git_path")
            self.assertEqual(context.exception.status, 400)

    def test_diff_is_bounded(self):
        (self.root / "large.txt").write_text("x" * (workspace_tools.MAX_DIFF_BYTES * 2), encoding="utf-8")
        payload = workspace_tools.git_diff(self.root, "large.txt", "untracked")
        self.assertTrue(payload["truncated"])
        self.assertLessEqual(len(payload["diff"].encode()), workspace_tools.MAX_DIFF_BYTES)

    def test_bounded_command_output_uses_files_instead_of_memory_capture(self):
        def fake_run(command, **options):
            self.assertNotIn("capture_output", options)
            self.assertNotIn("text", options)
            options["stdout"].write(b"x" * 1024)
            options["stderr"].write(b"warning")
            return subprocess.CompletedProcess(command, 0)

        with patch("herdr_harness.workspace_tools.subprocess.run", side_effect=fake_run):
            output, truncated = workspace_tools._run(
                ["git", "diff"],
                maximum_bytes=64,
            )

        self.assertTrue(truncated)
        self.assertLessEqual(len(output.encode("utf-8")), 64)
        self.assertTrue(output.endswith("...[truncated]..."))

    def test_skills_and_file_search_are_project_scoped_and_ignore_build_content(self):
        project_skill = self.root / ".claude" / "skills" / "ship-it" / "SKILL.md"
        project_skill.parent.mkdir(parents=True)
        project_skill.write_text("# Ship it", encoding="utf-8")
        source = self.root / "Sources" / "FeaturePane.swift"
        source.parent.mkdir()
        source.write_text("struct FeaturePane {}", encoding="utf-8")
        ignored = self.root / "node_modules" / "FeaturePane.js"
        ignored.parent.mkdir()
        ignored.write_text("ignored", encoding="utf-8")

        home = Path(self.temporary.name) / "home"
        user_skill = home / ".claude" / "skills" / "review" / "SKILL.md"
        user_skill.parent.mkdir(parents=True)
        user_skill.write_text("# Review", encoding="utf-8")

        skill_payload = workspace_tools.skills(self.root, environ={"HOME": str(home)})
        search_payload = workspace_tools.search_files(self.root, "FeaturePane", limit=10)

        self.assertEqual(skill_payload["project_skills"][0]["skill_file_path"], ".claude/skills/ship-it/SKILL.md")
        self.assertEqual(skill_payload["user_skills"][0]["skill_file_path"], "~/.claude/skills/review/SKILL.md")
        self.assertEqual(search_payload["files"], [{"path": "Sources/FeaturePane.swift"}])

    def test_skills_and_file_search_support_a_non_git_workspace_root(self):
        plain = Path(self.temporary.name) / "plain"
        skill = plain / ".claude" / "skills" / "local" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("# Local", encoding="utf-8")
        source = plain / "Notes.txt"
        source.write_text("notes", encoding="utf-8")

        skill_payload = workspace_tools.skills(plain, environ={"HOME": str(plain / "home")})
        search_payload = workspace_tools.search_files(plain, "Notes", limit=5)

        self.assertEqual(skill_payload["project_skills"][0]["name"], "local")
        self.assertEqual(search_payload["files"], [{"path": "Notes.txt"}])

    def test_skills_map_claude_managed_worktrees_back_to_the_project_root(self):
        project_skill = self.root / ".claude" / "skills" / "project-review" / "SKILL.md"
        project_skill.parent.mkdir(parents=True)
        project_skill.write_text("# Project review", encoding="utf-8")

        managed_worktree = self.root / ".claude" / "worktrees" / "feature-a"
        managed_worktree.mkdir(parents=True)
        subprocess.run(
            ["git", "-C", str(managed_worktree), "init", "-q"],
            check=True,
            capture_output=True,
            text=True,
        )
        branch_file = managed_worktree / "BranchOnlyPane.swift"
        branch_file.write_text("struct BranchOnlyPane {}", encoding="utf-8")

        payload = workspace_tools.skills(
            managed_worktree,
            environ={"HOME": str(Path(self.temporary.name) / "home")},
        )
        search_payload = workspace_tools.search_files(
            managed_worktree,
            "BranchOnlyPane",
            limit=10,
        )

        self.assertEqual(payload["root_path"], str(self.root.resolve()))
        self.assertEqual(payload["project_skills"][0]["name"], "project-review")
        self.assertEqual(search_payload["root_path"], str(managed_worktree.resolve()))
        self.assertEqual(search_payload["files"], [{"path": "BranchOnlyPane.swift"}])

    def test_jira_uses_acli_argv_and_normalizes_external_fields(self):
        response = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                [
                    {
                        "key": "HERD-42",
                        "fields": {
                            "summary": "Polish pane\u0000",
                            "status": {"name": "In Progress"},
                            "priority": {"name": "High"},
                            "issuetype": {"name": "Story"},
                        },
                    }
                ]
            ),
            stderr="",
        )
        with patch("herdr_harness.workspace_tools.subprocess.run", return_value=response) as run:
            payload = workspace_tools.jira_assigned(
                project="HERD",
                limit=12,
                environ={"HERDR_HARNESS_JIRA_SITE": "https://jira.example.test/"},
            )

        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["acli", "jira", "workitem", "search"])
        self.assertIn("project = HERD", command[command.index("--jql") + 1])
        self.assertEqual(payload["tickets"][0]["project_key"], "HERD")
        self.assertEqual(payload["tickets"][0]["issue_type"], "Story")
        self.assertEqual(payload["tickets"][0]["url"], "https://jira.example.test/browse/HERD-42")

    def test_invalid_jira_values_are_rejected_before_process_launch(self):
        with patch("herdr_harness.workspace_tools.subprocess.run") as run:
            with self.assertRaises(workspace_tools.WorkspaceToolError):
                workspace_tools.jira_assigned(project="BAD; rm", environ={})
            with self.assertRaises(workspace_tools.WorkspaceToolError):
                workspace_tools.jira_issue("not-a-ticket", environ={})
        run.assert_not_called()


class AttachmentTests(unittest.TestCase):
    def test_attachment_is_sanitized_private_and_workspace_scoped(self):
        with tempfile.TemporaryDirectory() as temporary:
            attachment = attachments.save_base64_attachment(
                workspace_id="w1:feature",
                filename="../../design notes.txt",
                content_type="text/plain",
                data_base64=base64.b64encode(b"hello").decode(),
                environ={"HERDR_HARNESS_ATTACHMENTS_DIR": temporary},
            )
            path = Path(attachment["path"])
            self.assertEqual(path.read_bytes(), b"hello")
            self.assertEqual(path.parent.name, "w1-feature")
            self.assertEqual(attachment["original_filename"], "design notes.txt")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_attachment_rejects_invalid_base64_and_decoded_size_limit(self):
        with self.assertRaises(attachments.AttachmentError):
            attachments.save_base64_attachment(
                workspace_id="w1",
                filename="bad.bin",
                content_type="application/octet-stream",
                data_base64="!!!",
                environ={},
            )
        with patch("herdr_harness.attachments.MAX_ATTACHMENT_BYTES", 3):
            with self.assertRaises(attachments.AttachmentError) as context:
                attachments.save_base64_attachment(
                    workspace_id="w1",
                    filename="large.bin",
                    content_type="application/octet-stream",
                    data_base64=base64.b64encode(b"1234").decode(),
                    environ={},
                )
        self.assertEqual(context.exception.status, 413)

    def test_ttl_pruning_can_be_limited_to_one_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = {"HERDR_HARNESS_ATTACHMENTS_DIR": temporary}
            first = attachments.save_base64_attachment(
                workspace_id="w1",
                filename="old.txt",
                content_type="text/plain",
                data_base64=base64.b64encode(b"old one").decode(),
                environ=environment,
            )
            fresh = attachments.save_base64_attachment(
                workspace_id="w1",
                filename="fresh.txt",
                content_type="text/plain",
                data_base64=base64.b64encode(b"fresh").decode(),
                environ=environment,
            )
            other = attachments.save_base64_attachment(
                workspace_id="w2",
                filename="other.txt",
                content_type="text/plain",
                data_base64=base64.b64encode(b"old two").decode(),
                environ=environment,
            )
            os.utime(first["path"], (100, 100))
            os.utime(fresh["path"], (950, 950))
            os.utime(other["path"], (100, 100))

            scoped = attachments.prune_expired_attachments(
                environ=environment,
                workspace_id="w1",
                retention=100,
                now=1_000,
            )

            self.assertEqual(scoped["deleted_files"], 1)
            self.assertFalse(Path(first["path"]).exists())
            self.assertTrue(Path(fresh["path"]).exists())
            self.assertTrue(Path(other["path"]).exists())

            global_cleanup = attachments.prune_expired_attachments(
                environ=environment,
                retention=100,
                now=1_000,
            )
            self.assertEqual(global_cleanup["deleted_files"], 1)
            self.assertFalse(Path(other["path"]).exists())

    def test_ttl_pruning_does_not_follow_symlinks_or_remove_fresh_upload_temps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "w1"
            workspace.mkdir()
            outside = root / "outside.txt"
            outside.write_text("outside", encoding="utf-8")
            symlink = workspace / "linked.txt"
            symlink.symlink_to(outside)
            fresh_temporary = workspace / ".upload.tmp"
            fresh_temporary.write_text("in progress", encoding="utf-8")
            os.utime(fresh_temporary, (950, 950))

            result = attachments.prune_expired_attachments(
                environ={"HERDR_HARNESS_ATTACHMENTS_DIR": temporary},
                retention=100,
                now=1_000,
            )

            self.assertEqual(result["deleted_files"], 0)
            self.assertTrue(outside.exists())
            self.assertTrue(symlink.is_symlink())
            self.assertTrue(fresh_temporary.exists())


if __name__ == "__main__":
    unittest.main()
