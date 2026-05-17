import tempfile
import unittest
from pathlib import Path

from cmux_harness import orchestrator_v2_storage as v2


class TestOrchestratorV2Storage(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        root = Path(self.tmpdir.name)
        self.repo = v2.V2Repository(root / "v2.sqlite3", root / "goals")
        self.workspace = root / "workspace"
        self.workspace.mkdir()

    def test_create_task_creates_goal_document_and_cmux_link(self):
        task = self.repo.create_task(
            {
                "title": "Ship V2 task board",
                "status": "To Do",
                "priority": "High",
                "workspaceDir": str(self.workspace),
                "sessionLaunchType": "Empty shell",
                "tags": [{"tag": "frontend", "color": "#2563eb"}],
            },
            cmux_session={
                "workspaceId": "workspace-1",
                "surfaceId": "surface-1",
                "title": "V2 Shell",
                "cwd": str(self.workspace),
            },
        )

        self.assertEqual(task["title"], "Ship V2 task board")
        self.assertEqual(task["workspaceDir"], str(self.workspace))
        self.assertEqual(task["cmuxSessionLinks"][0]["workspaceId"], "workspace-1")
        self.assertEqual(task["tags"][0]["tag"], "frontend")
        goal = self.repo.read_goal(task["id"])
        self.assertTrue(Path(goal["path"]).exists())
        self.assertIn("# Ship V2 task board", goal["content"])
        self.assertIn("Discuss Goal", goal["content"])

    def test_done_and_archived_are_hidden_from_active_task_board(self):
        active = self.repo.create_task({"title": "Active", "workspaceDir": str(self.workspace)})
        done = self.repo.create_task({"title": "Done item", "workspaceDir": str(self.workspace), "status": "Done"})
        archived = self.repo.create_task({"title": "Archived item", "workspaceDir": str(self.workspace), "status": "Archived"})

        active_ids = {task["id"] for task in self.repo.list_tasks()}
        all_ids = {task["id"] for task in self.repo.list_tasks(include_history=True)}

        self.assertIn(active["id"], active_ids)
        self.assertNotIn(done["id"], active_ids)
        self.assertNotIn(archived["id"], active_ids)
        self.assertTrue({active["id"], done["id"], archived["id"]}.issubset(all_ids))

    def test_task_supports_many_jira_pr_and_cmux_links(self):
        task = self.repo.create_task({"title": "Resource fan-in", "workspaceDir": str(self.workspace)})

        self.repo.attach_jira(task["id"], {"key": "APP-1", "title": "First", "status": "In Progress"})
        self.repo.attach_jira(task["id"], {"key": "APP-2", "title": "Second", "status": "To Do"})
        self.repo.attach_pr(task["id"], {"owner": "org", "repo": "repo", "number": 10, "title": "One", "url": "https://github.com/org/repo/pull/10", "isPrimary": True})
        self.repo.attach_pr(task["id"], {"owner": "org", "repo": "repo", "number": 11, "title": "Two", "url": "https://github.com/org/repo/pull/11"})
        self.repo.attach_cmux_session(task["id"], {"workspaceId": "workspace-a", "surfaceId": "surface-a"})
        self.repo.attach_cmux_session(task["id"], {"workspaceId": "workspace-b", "surfaceId": "surface-b"})

        hydrated = self.repo.get_task(task["id"])

        self.assertEqual([link["key"] for link in hydrated["jiraLinks"]], ["APP-1", "APP-2"])
        self.assertEqual(len(hydrated["pullRequestLinks"]), 2)
        self.assertEqual(len(hydrated["cmuxSessionLinks"]), 2)
        self.assertTrue(hydrated["pullRequestLinks"][0]["isPrimary"])

    def test_cmux_session_cannot_attach_to_multiple_tasks(self):
        first = self.repo.create_task({"title": "First", "workspaceDir": str(self.workspace)})
        second = self.repo.create_task({"title": "Second", "workspaceDir": str(self.workspace)})
        self.repo.attach_cmux_session(first["id"], {"workspaceId": "workspace-a", "surfaceId": "surface-a"})

        with self.assertRaises(v2.V2StorageError) as context:
            self.repo.attach_cmux_session(second["id"], {"workspaceId": "workspace-a", "surfaceId": "surface-a"})

        self.assertEqual(context.exception.status, 409)

    def test_active_unlinked_sessions_are_recorded_as_orphans(self):
        task = self.repo.create_task(
            {"title": "Linked", "workspaceDir": str(self.workspace)},
            cmux_session={"workspaceId": "linked", "surfaceId": "surface-1"},
        )
        self.repo.record_cmux_snapshots([
            {"workspaceId": "linked", "surfaceId": "surface-1", "title": "Linked"},
            {"workspaceId": "orphan", "surfaceId": "surface-2", "title": "Loose shell"},
        ])

        orphans = self.repo.list_orphans()

        self.assertEqual(len(orphans), 1)
        self.assertEqual(orphans[0]["workspaceId"], "orphan")
        self.assertEqual(self.repo.get_task(task["id"])["cmuxSessionLinks"][0]["workspaceId"], "linked")

    def test_goal_update_audit_and_activity_are_persistent(self):
        task = self.repo.create_task({"title": "Goal edit", "workspaceDir": str(self.workspace)})

        self.repo.update_goal(task["id"], "# Revised\n\nDo the thing.", actor="agent")
        audit = self.repo.list_audit_events()
        activity = self.repo.list_activity_events()

        self.assertIn("Revised", self.repo.read_goal(task["id"])["content"])
        self.assertEqual(audit[0]["action"], "update_goal_markdown")
        self.assertEqual(activity[0]["kind"], "goal_updated")

    def test_agent_runs_agui_events_and_tool_runs_are_persistent(self):
        self.repo.create_agent_run("run-1", mode="text", input_payload={"message": "status"})
        self.repo.record_agui_event("run-1", {"type": "RUN_STARTED", "runId": "run-1"})
        self.repo.record_tool_run("run-1", "list_tasks", {}, {"count": 0})
        finished = self.repo.finish_agent_run("run-1", status="completed", output_payload={"text": "done"})

        self.assertEqual(finished["status"], "completed")
        self.assertEqual(self.repo.list_agui_events("run-1")[0]["type"], "RUN_STARTED")
        self.assertEqual(self.repo.list_tool_runs(run_id="run-1")[0]["toolName"], "list_tasks")

    def test_secret_shaped_values_are_redacted_before_persistence(self):
        self.repo.append_chat_message("user", "token sk-1234567890abcdefSECRET should disappear", {"Authorization": "Bearer abcdefghijklmnop"})
        self.repo.record_tool_run("run-2", "secret_tool", {"apiKey": "fw_abcdefghijklmnop"}, {"token": "ek_abcdefghijklmnop"})

        message = self.repo.list_chat_messages()[0]
        tool_run = self.repo.list_tool_runs(run_id="run-2")[0]

        self.assertIn("[REDACTED]", message["content"])
        self.assertEqual(tool_run["input"]["apiKey"], "[REDACTED]")
        self.assertEqual(tool_run["output"]["token"], "[REDACTED]")


if __name__ == "__main__":
    unittest.main()
