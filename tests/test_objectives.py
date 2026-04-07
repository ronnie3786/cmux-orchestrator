import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import objectives


class TestObjectives(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_objectives_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.patch_subprocess_run = patch("cmux_harness.objectives.subprocess.run")
        self.mock_run = self.patch_subprocess_run.start()
        self.addCleanup(self.patch_subprocess_run.stop)
        self.mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")

    def _write_legacy_objective(self, objective_id, payload):
        objective_dir = self.objectives_dir / objective_id
        objective_dir.mkdir(parents=True)
        (objective_dir / "objective.json").write_text(json.dumps(payload), encoding="utf-8")
        return objective_dir

    def test_create_objective_creates_directory_and_json(self):
        project_dir = Path(self.tmpdir.name) / "project"
        objective = objectives.create_objective("Ship feature", str(project_dir), base_branch="develop")

        objective_dir = self.objectives_dir / objective["id"]
        self.assertTrue(objective_dir.is_dir())
        self.assertEqual(objective["goal"], "Ship feature")
        self.assertEqual(objective["projectDir"], str(project_dir))
        self.assertEqual(objective["baseBranch"], "develop")
        self.assertEqual(objective["status"], "planning")
        self.assertEqual(objective["workflowMode"], "structured")
        self.assertTrue(objective["projectId"])
        self.assertEqual(objective["tasks"], [])
        self.assertEqual(objective["branchName"], f"orchestrator/{objective['id'][:8]}")
        self.assertEqual(
            objective["worktreePath"],
            str(project_dir / ".cmux-harness" / "worktrees" / f"orchestrator-{objective['id'][:8]}"),
        )

        on_disk = json.loads((objective_dir / "objective.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["id"], objective["id"])
        self.assertEqual(on_disk["branchName"], objective["branchName"])
        self.assertEqual(objectives.read_project(objective["projectId"])["rootPath"], str(project_dir))
        self.assertEqual(
            self.mock_run.call_args_list[-1],
            unittest.mock.call(
                [
                    "git",
                    "-C",
                    str(project_dir),
                    "worktree",
                    "add",
                    objective["worktreePath"],
                    "-b",
                    objective["branchName"],
                    "develop",
                ],
                capture_output=True,
                text=True,
                check=True,
            ),
        )

    def test_create_objective_uses_supplied_branch_name(self):
        project_dir = Path(self.tmpdir.name) / "project"

        objective = objectives.create_objective(
            "Ship feature",
            str(project_dir),
            base_branch="main",
            branch_name="feature/test-branch",
        )

        self.assertEqual(objective["branchName"], "feature/test-branch")
        self.assertEqual(
            objective["worktreePath"],
            str(project_dir / ".cmux-harness" / "worktrees" / "feature-test-branch"),
        )

    def test_create_objective_reuses_existing_branch_when_branch_exists(self):
        project_dir = Path(self.tmpdir.name) / "project"
        self.mock_run.side_effect = [
            subprocess.CalledProcessError(returncode=1, cmd=["git"], stderr="branch already exists"),
            subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr=""),
        ]

        objective = objectives.create_objective("Ship feature", str(project_dir), branch_name="feature/existing")

        self.assertEqual(objective["branchName"], "feature/existing")
        self.assertEqual(self.mock_run.call_count, 2)
        self.assertEqual(
            self.mock_run.call_args_list[1],
            unittest.mock.call(
                [
                    "git",
                    "-C",
                    str(project_dir),
                    "worktree",
                    "add",
                    objective["worktreePath"],
                    "feature/existing",
                ],
                capture_output=True,
                text=True,
                check=True,
            ),
        )

    def test_read_objective_returns_data(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        loaded = objectives.read_objective(objective["id"])

        self.assertEqual(loaded["id"], objective["id"])
        self.assertEqual(loaded["goal"], "Ship feature")

    def test_update_objective_merges_updates(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        original_updated_at = objective["updatedAt"]

        updated = objectives.update_objective(objective["id"], {"status": "executing", "tasks": [{"id": "task-1"}]})

        self.assertEqual(updated["status"], "executing")
        self.assertEqual(updated["tasks"], [{"id": "task-1"}])
        self.assertNotEqual(updated["updatedAt"], original_updated_at)
        self.assertEqual(updated["goal"], "Ship feature")

    def test_list_objectives_returns_all(self):
        first = objectives.create_objective("First", "/tmp/one")
        second = objectives.create_objective("Second", "/tmp/two")

        listed = objectives.list_objectives()

        self.assertEqual({item["id"] for item in listed}, {first["id"], second["id"]})

    def test_create_task_dir_creates_expected_files(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        task_dir = objectives.create_task_dir(objective["id"], "task-1")

        self.assertTrue(task_dir.is_dir())
        self.assertEqual((task_dir / "spec.md").read_text(encoding="utf-8"), "")
        self.assertEqual((task_dir / "context.md").read_text(encoding="utf-8"), "")
        self.assertEqual((task_dir / "progress.md").read_text(encoding="utf-8"), "")

    def test_read_and_write_task_file(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")
        objectives.create_task_dir(objective["id"], "task-1")

        objectives.write_task_file(objective["id"], "task-1", "result.md", "done")
        content = objectives.read_task_file(objective["id"], "task-1", "result.md")

        self.assertEqual(content, "done")
        self.assertIsNone(objectives.read_task_file(objective["id"], "task-1", "missing.md"))

    def test_get_objective_worktree_path_reads_from_objective(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        self.assertEqual(objectives.get_objective_worktree_path(objective["id"]), objective["worktreePath"])
        self.assertIsNone(objectives.get_objective_worktree_path("missing"))

    def test_delete_objective_removes_directory(self):
        objective = objectives.create_objective("Ship feature", "/tmp/project")

        self.assertTrue(objectives.delete_objective(objective["id"]))
        self.assertFalse((self.objectives_dir / objective["id"]).exists())
        self.assertFalse(objectives.delete_objective(objective["id"]))
        self.assertEqual(self.mock_run.call_args_list[-1][0][0][:4], ["git", "-C", "/tmp/project", "worktree"])

    def test_create_project_requires_existing_git_repo_root(self):
        root_path = Path(self.tmpdir.name) / "manual-project"
        root_path.mkdir()

        project = objectives.create_project("Manual Project", str(root_path), "develop")

        self.assertEqual(project["name"], "Manual Project")
        self.assertEqual(project["rootPath"], str(root_path))
        self.assertEqual(project["defaultBaseBranch"], "develop")
        self.assertEqual(
            self.mock_run.call_args_list[-1],
            unittest.mock.call(
                ["git", "-C", str(root_path), "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                check=True,
            ),
        )

    def test_create_project_rejects_duplicate_root_path(self):
        root_path = Path(self.tmpdir.name) / "duplicate-project"
        root_path.mkdir()
        objectives.create_project("One", str(root_path), "main")

        with self.assertRaises(ValueError):
            objectives.create_project("Two", str(root_path), "main")

    def test_delete_project_requires_no_objectives(self):
        root_path = Path(self.tmpdir.name) / "delete-guard-project"
        root_path.mkdir()
        project = objectives.create_project("Guarded", str(root_path), "main")
        objectives.create_objective("Ship feature", project_id=project["id"])

        with self.assertRaises(ValueError):
            objectives.delete_project(project["id"])

    def test_create_objective_uses_project_default_branch_and_workflow_mode(self):
        root_path = Path(self.tmpdir.name) / "configured-project"
        root_path.mkdir()
        project = objectives.create_project("Configured", str(root_path), "develop")

        objective = objectives.create_objective(
            "Ship feature",
            project_id=project["id"],
            workflow_mode="direct",
        )

        self.assertEqual(objective["projectId"], project["id"])
        self.assertEqual(objective["projectDir"], str(root_path))
        self.assertEqual(objective["baseBranch"], "develop")
        self.assertEqual(objective["workflowMode"], "direct")
        self.assertEqual(
            self.mock_run.call_args_list[-1],
            unittest.mock.call(
                [
                    "git",
                    "-C",
                    str(root_path),
                    "worktree",
                    "add",
                    objective["worktreePath"],
                    "-b",
                    objective["branchName"],
                    "develop",
                ],
                capture_output=True,
                text=True,
                check=True,
            ),
        )

    def test_create_objective_project_override_wins_over_project_default_branch(self):
        root_path = Path(self.tmpdir.name) / "override-branch-project"
        root_path.mkdir()
        project = objectives.create_project("Configured", str(root_path), "develop")

        objective = objectives.create_objective(
            "Ship feature",
            project_id=project["id"],
            base_branch="release/2026",
        )

        self.assertEqual(objective["projectId"], project["id"])
        self.assertEqual(objective["baseBranch"], "release/2026")
        self.assertEqual(
            self.mock_run.call_args_list[-1],
            unittest.mock.call(
                [
                    "git",
                    "-C",
                    str(root_path),
                    "worktree",
                    "add",
                    objective["worktreePath"],
                    "-b",
                    objective["branchName"],
                    "release/2026",
                ],
                capture_output=True,
                text=True,
                check=True,
            ),
        )

    def test_create_objective_invalid_workflow_mode_falls_back_to_structured(self):
        root_path = Path(self.tmpdir.name) / "workflow-mode-project"
        root_path.mkdir()
        project = objectives.create_project("Configured", str(root_path), "main")

        objective = objectives.create_objective(
            "Ship feature",
            project_id=project["id"],
            workflow_mode="ship-it",
        )

        self.assertEqual(objective["workflowMode"], "structured")

    def test_read_objective_migrates_legacy_objective_missing_only_project_id(self):
        objective_id = "legacy-missing-project"
        legacy_root = Path(self.tmpdir.name) / "legacy-project-only-project-id"
        legacy_root.mkdir()
        self._write_legacy_objective(
            objective_id,
            {
                "id": objective_id,
                "goal": "Legacy goal",
                "status": "planning",
                "projectDir": str(legacy_root),
                "baseBranch": "release",
                "branchName": "orchestrator/legacy-project",
                "worktreePath": str(legacy_root / ".cmux-harness" / "worktrees" / "orchestrator-legacy-project"),
                "workflowMode": "direct",
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )

        loaded = objectives.read_objective(objective_id)

        self.assertTrue(loaded["projectId"])
        self.assertEqual(loaded["workflowMode"], "direct")
        self.assertEqual(loaded["baseBranch"], "release")
        self.assertEqual(objectives.read_project(loaded["projectId"])["rootPath"], str(legacy_root))

    def test_read_objective_migrates_legacy_objective_missing_only_workflow_mode(self):
        root_path = Path(self.tmpdir.name) / "legacy-existing-project"
        root_path.mkdir()
        project = objectives.create_project("Existing", str(root_path), "develop")
        objective_id = "legacy-missing-workflow"
        self._write_legacy_objective(
            objective_id,
            {
                "id": objective_id,
                "goal": "Legacy goal",
                "status": "planning",
                "projectId": project["id"],
                "projectDir": str(root_path),
                "baseBranch": "develop",
                "branchName": "orchestrator/legacy-workflow",
                "worktreePath": str(root_path / ".cmux-harness" / "worktrees" / "orchestrator-legacy-workflow"),
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )

        loaded = objectives.read_objective(objective_id)

        self.assertEqual(loaded["projectId"], project["id"])
        self.assertEqual(loaded["workflowMode"], "structured")

    def test_read_objective_migrates_multiple_legacy_objectives_from_same_repo_to_one_project(self):
        shared_root = Path(self.tmpdir.name) / "shared-legacy-root"
        shared_root.mkdir()
        self._write_legacy_objective(
            "legacy-one",
            {
                "id": "legacy-one",
                "goal": "One",
                "status": "planning",
                "projectDir": str(shared_root),
                "baseBranch": "main",
                "branchName": "orchestrator/legacy-one",
                "worktreePath": str(shared_root / ".cmux-harness" / "worktrees" / "legacy-one"),
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )
        self._write_legacy_objective(
            "legacy-two",
            {
                "id": "legacy-two",
                "goal": "Two",
                "status": "planning",
                "projectDir": str(shared_root),
                "baseBranch": "develop",
                "branchName": "orchestrator/legacy-two",
                "worktreePath": str(shared_root / ".cmux-harness" / "worktrees" / "legacy-two"),
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )

        first = objectives.read_objective("legacy-one")
        second = objectives.read_objective("legacy-two")

        self.assertEqual(first["projectId"], second["projectId"])
        self.assertEqual(len(objectives.list_projects()), 1)

    def test_read_objective_migrates_legacy_objective_with_missing_base_branch_safely(self):
        objective_id = "legacy-missing-base-branch"
        legacy_root = Path(self.tmpdir.name) / "legacy-no-base"
        legacy_root.mkdir()
        self._write_legacy_objective(
            objective_id,
            {
                "id": objective_id,
                "goal": "Legacy goal",
                "status": "planning",
                "projectDir": str(legacy_root),
                "baseBranch": "",
                "branchName": "orchestrator/legacy-no-base",
                "worktreePath": str(legacy_root / ".cmux-harness" / "worktrees" / "legacy-no-base"),
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )

        loaded = objectives.read_objective(objective_id)

        self.assertEqual(loaded["baseBranch"], "main")
        self.assertEqual(objectives.read_project(loaded["projectId"])["defaultBaseBranch"], "main")

    def test_read_objective_migrates_legacy_objective_to_project_and_workflow_mode(self):
        objective_id = "legacy-objective"
        legacy_root = Path(self.tmpdir.name) / "legacy-project"
        legacy_root.mkdir()
        self._write_legacy_objective(
            objective_id,
            {
                "id": objective_id,
                "goal": "Legacy goal",
                "status": "planning",
                "projectDir": str(legacy_root),
                "baseBranch": "release",
                "branchName": "orchestrator/legacy",
                "worktreePath": str(legacy_root / ".cmux-harness" / "worktrees" / "orchestrator-legacy"),
                "createdAt": "2026-04-07T00:00:00+00:00",
                "updatedAt": "2026-04-07T00:00:00+00:00",
                "tasks": [],
            },
        )

        loaded = objectives.read_objective(objective_id)

        self.assertTrue(loaded["projectId"])
        self.assertEqual(loaded["workflowMode"], "structured")
        project = objectives.read_project(loaded["projectId"])
        self.assertEqual(project["rootPath"], str(legacy_root))
        on_disk = json.loads((self.objectives_dir / objective_id / "objective.json").read_text(encoding="utf-8"))
        self.assertEqual(on_disk["projectId"], loaded["projectId"])
        self.assertEqual(on_disk["workflowMode"], "structured")


if __name__ == "__main__":
    unittest.main()
