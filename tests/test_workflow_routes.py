import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import objectives
from cmux_harness import workspaces
from cmux_harness.routes import workflow


class TestWorkflowRoutes(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.workspaces_dir = Path(self.tmpdir.name) / "workspaces"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_workspaces_dir = patch.object(workspaces, "WORKSPACES_DIR", self.workspaces_dir)
        self.patch_objectives_dir.start()
        self.patch_workspaces_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.addCleanup(self.patch_workspaces_dir.stop)
        self.patch_jira = patch.object(workflow, "fetch_assigned_jira")
        self.mock_fetch_jira = self.patch_jira.start()
        self.mock_fetch_jira.return_value = {"ok": True, "tickets": [], "error": None}
        self.addCleanup(self.patch_jira.stop)

    def _write_objective(self, objective_id="obj-1", **overrides):
        objective_dir = self.objectives_dir / objective_id
        objective_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "id": objective_id,
            "goal": "Ship workflow APIs",
            "status": "running",
            "projectDir": self.tmpdir.name,
            "baseBranch": "main",
            "tasks": [],
            "workflowMode": "structured",
            "createdAt": "2026-05-10T00:00:00+00:00",
            "updatedAt": "2026-05-10T00:00:00+00:00",
        }
        payload.update(overrides)
        (objective_dir / "objective.json").write_text(json.dumps(payload), encoding="utf-8")
        return payload

    def test_workflow_storage_follows_patched_objectives_directory(self):
        idea = workflow.create_idea({"title": "Pre-Jira grooming", "summary": "Capture rough work first."})
        expected_path = self.objectives_dir.parent / "workflow" / "ideas" / idea["id"] / "idea.json"

        self.assertTrue(expected_path.exists())
        self.assertEqual(workflow.workflow_dir(), self.objectives_dir.parent / "workflow")
        self.assertEqual(workflow.list_ideas()[0]["title"], "Pre-Jira grooming")

    def test_command_center_aggregates_ideas_jira_objectives_decisions_and_context(self):
        self._write_objective()
        workflow.update_context_dimension(
            "obj-1",
            "open_questions",
            {"state": "unresolved", "required": True, "count": 2, "reason": "Needs API shape."},
        )
        workflow.create_idea({"title": "Voice intake"})
        workflow.create_decision({"title": "Approve Jira comment", "recommendation": "Post the prepared summary."})
        self.mock_fetch_jira.return_value = {
            "ok": True,
            "tickets": [{"key": "ENG-123", "title": "Add command center", "status": "To Do", "url": "https://jira.example/ENG-123"}],
            "error": None,
        }

        payload = workflow.command_center_payload()

        self.assertTrue(payload["ok"])
        self.assertEqual(payload["summary"]["ideas"], 1)
        self.assertEqual(payload["summary"]["assignedJira"], 1)
        self.assertEqual(payload["summary"]["objectivesWatched"], 1)
        self.assertGreaterEqual(payload["summary"]["needsRonnie"], 1)
        self.assertEqual(payload["topPriority"]["recommendedAction"], "review_decision")
        lanes = {lane["id"]: lane for lane in payload["lanes"]}
        self.assertEqual(lanes["ideas"]["cards"][0]["title"], "Voice intake")
        self.assertEqual(lanes["intake"]["cards"][0]["id"], "ENG-123")
        context_cards = lanes["context"]["cards"]
        self.assertEqual(context_cards[0]["id"], "obj-1")
        self.assertEqual(context_cards[0]["contextHealth"]["state"], "needs_attention")


    def test_preflight_from_idea_surfaces_in_context_lane(self):
        idea = workflow.create_idea({"title": "Voice-first Jira intake", "summary": "Needs context before launch."})

        preflight = workflow.create_preflight({"sourceType": "idea", "sourceId": idea["id"]})
        payload = workflow.command_center_payload()

        self.assertEqual(preflight["sourceType"], "idea")
        self.assertEqual(preflight["sourceId"], idea["id"])
        self.assertEqual(workflow.read_idea(idea["id"])["status"], "ready_for_jira")
        self.assertEqual(payload["summary"]["preflights"], 1)
        lanes = {lane["id"]: lane for lane in payload["lanes"]}
        self.assertEqual(lanes["context"]["cards"][0]["type"], "preflight")
        self.assertEqual(lanes["context"]["cards"][0]["id"], preflight["id"])
        self.assertEqual(lanes["context"]["cards"][0]["contextHealth"]["state"], "needs_attention")

    def test_preflight_from_jira_keeps_ticket_source(self):
        preflight = workflow.create_preflight({
            "sourceType": "jira",
            "sourceId": "IOSDOX-26059",
            "title": "Fix recorder reset errors",
            "summary": "Assigned bug needs readiness pass.",
            "sourceUrl": "https://jira.example/IOSDOX-26059",
        })

        self.assertEqual(preflight["sourceType"], "jira")
        self.assertEqual(preflight["sourceId"], "IOSDOX-26059")
        self.assertEqual(preflight["sourceUrl"], "https://jira.example/IOSDOX-26059")
        self.assertEqual(preflight["requiredContext"][1]["id"], "jira")
        self.assertEqual(preflight["requiredContext"][1]["state"], "resolved")


    def test_preflight_readiness_requires_project_and_required_context(self):
        preflight = workflow.create_preflight({"title": "Needs repo", "requiredContext": [{"id": "open_questions", "label": "Open questions", "state": "resolved", "required": True}]})

        self.assertFalse(preflight["launchReady"])
        self.assertEqual(preflight["missingRequirements"][0]["id"], "project")

        ready = workflow.update_preflight(preflight["id"], {"projectDir": self.tmpdir.name})

        self.assertTrue(ready["launchReady"])
        self.assertEqual(ready["status"], "ready_for_objective")
        self.assertEqual(ready["missingRequirements"], [])

    def test_preflight_card_includes_launch_plan_and_context_checklist(self):
        preflight = workflow.create_preflight({"title": "Plan the launch", "projectDir": self.tmpdir.name})
        card = workflow._preflight_card(preflight)

        self.assertEqual(card["launchPlan"]["ready"], False)
        self.assertEqual(card["launchPlan"]["nextAction"], "Resolve 1 launch requirement(s)")
        self.assertEqual(card["launchPlan"]["steps"][0]["id"], "context")
        self.assertEqual(card["launchPlan"]["steps"][0]["state"], "blocked")
        self.assertEqual(card["requiredContext"][0]["id"], "open_questions")

        updated_context = [dict(item, state="resolved") if item.get("id") == "open_questions" else item for item in card["requiredContext"]]
        ready = workflow.update_preflight(preflight["id"], {"requiredContext": updated_context})
        ready_card = workflow._preflight_card(ready)

        self.assertTrue(ready_card["launchPlan"]["ready"])
        self.assertEqual(ready_card["launchPlan"]["nextAction"], "Launch objective")
        self.assertEqual(ready_card["launchPlan"]["steps"][-1]["state"], "ready")

    def test_launch_preflight_blocks_until_required_context_is_resolved(self):
        preflight = workflow.create_preflight({"title": "Blocked launch", "projectDir": self.tmpdir.name})

        objective, error = workflow.launch_preflight_objective(preflight["id"], {})

        self.assertIsNone(objective)
        self.assertIn("Open questions", error)

    def test_launch_preflight_creates_objective_and_moves_card_to_running(self):
        repo = Path(self.tmpdir.name) / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True, text=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True, capture_output=True, text=True)
        preflight = workflow.create_preflight({
            "title": "Ship objective flow",
            "summary": "Launch from web pre-flight.",
            "requiredContext": [{"id": "open_questions", "label": "Open questions", "state": "resolved", "required": True}],
        })

        objective, error = workflow.launch_preflight_objective(preflight["id"], {"projectDir": str(repo), "baseBranch": "main"})
        payload = workflow.command_center_payload()
        lanes = {lane["id"]: lane for lane in payload["lanes"]}

        self.assertIsNone(error)
        self.assertEqual(objective["goal"], "Ship objective flow")
        launched_preflight = workflow.read_preflight(preflight["id"])
        checkins = workflow.list_checkins(limit=3)

        self.assertEqual(launched_preflight["objectiveId"], objective["id"])
        self.assertEqual(launched_preflight["status"], "launched")
        self.assertIn("launchedAt", launched_preflight)
        self.assertEqual(launched_preflight["launchSummary"]["branchName"], objective["branchName"])
        self.assertEqual(launched_preflight["launchSummary"]["worktreePath"], objective["worktreePath"])
        self.assertEqual(launched_preflight["launchSummary"]["nextAction"], "Watch planner output")
        self.assertEqual(launched_preflight["launchSummary"]["detailUrl"], f"/api/objectives/{objective['id']}")
        running_card = lanes["running"]["cards"][0]
        self.assertEqual(running_card["id"], objective["id"])
        self.assertEqual(running_card["type"], "objective")
        self.assertEqual(running_card["sourcePreflightId"], preflight["id"])
        self.assertEqual(running_card["launchSummary"]["branchName"], objective["branchName"])
        self.assertEqual(running_card["launchSummary"]["worktreePath"], objective["worktreePath"])
        self.assertEqual(running_card["launchSummary"]["nextAction"], "Watch planner output")
        self.assertFalse([card for card in lanes["running"]["cards"] if card.get("type") == "preflight"])
        self.assertEqual(checkins[0]["targetType"], "objective")
        self.assertEqual(checkins[0]["targetId"], objective["id"])
        self.assertIn("Launched objective from pre-flight", checkins[0]["summary"])

    def test_review_ready_objective_moves_to_review_lane(self):
        self._write_objective(status="review", summary="Ready for Ronnie to inspect.")

        payload = workflow.command_center_payload()
        lanes = {lane["id"]: lane for lane in payload["lanes"]}

        self.assertEqual(lanes["review"]["cards"][0]["id"], "obj-1")
        self.assertEqual(lanes["review"]["cards"][0]["summary"], "Ready for Ronnie to inspect.")
        self.assertEqual(payload["summary"]["reviewReady"], 1)

    def test_completed_objective_moves_to_done_lane(self):
        self._write_objective(status="completed", summary="Reviewed and accepted from the web handoff.")

        payload = workflow.command_center_payload()
        lanes = {lane["id"]: lane for lane in payload["lanes"]}
        briefing = workflow.briefing_payload()

        self.assertEqual(lanes["done"]["cards"][0]["id"], "obj-1")
        self.assertEqual(lanes["done"]["cards"][0]["summary"], "Reviewed and accepted from the web handoff.")
        self.assertEqual(lanes["review"]["cards"], [])
        self.assertEqual(payload["summary"]["reviewReady"], 0)
        self.assertEqual(payload["summary"]["completed"], 1)
        self.assertEqual(briefing["counts"]["completed"], 1)

    def test_briefing_surfaces_running_objective_next_action_after_launch(self):
        repo = Path(self.tmpdir.name) / "repo-briefing"
        repo.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True, text=True)
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True, capture_output=True, text=True)
        preflight = workflow.create_preflight({
            "title": "Launch briefing flow",
            "requiredContext": [{"id": "open_questions", "label": "Open questions", "state": "resolved", "required": True}],
        })
        objective, error = workflow.launch_preflight_objective(preflight["id"], {"projectDir": str(repo), "baseBranch": "main"})

        briefing = workflow.briefing_payload()

        self.assertIsNone(error)
        self.assertIn("active objective", briefing["headline"])
        self.assertEqual(briefing["nextActions"][0]["kind"], "objective")
        self.assertEqual(briefing["nextActions"][0]["label"], "Watch planner output")
        self.assertEqual(briefing["nextActions"][0]["target"]["id"], objective["id"])
        self.assertEqual(briefing["watchlist"][0]["sourcePreflightId"], preflight["id"])
        self.assertEqual(briefing["watchlist"][0]["nextAction"], "Watch planner output")

    def test_checkin_synthesizes_signals_health_and_recommended_action(self):
        self._write_objective(status="completed")
        workflow.create_idea({"title": "Product shell"})
        workflow.create_decision({"title": "Pick launch path"})

        checkin = workflow.create_checkin({"targetType": "all"})

        self.assertIn("1 objectives watched", checkin["summary"])
        self.assertIn("1 ideas", checkin["summary"])
        self.assertIn("1 decisions need review", checkin["summary"])
        self.assertEqual(checkin["health"], "attention")
        self.assertEqual(checkin["recommendedAction"], "review_decisions")
        self.assertEqual(checkin["signals"]["needsRonnie"], 1)

    def test_context_dimension_patch_resolve_and_reopen_history(self):
        self._write_objective()

        waiting = workflow.update_context_dimension(
            "obj-1",
            "design",
            {"state": "waiting", "owner": "Design", "reason": "Need mock approval."},
            action="wait",
        )
        resolved = workflow.update_context_dimension("obj-1", "design", {"note": "Approved."}, action="resolve")
        reopened = workflow.update_context_dimension("obj-1", "design", {"note": "New concern."}, action="reopen")

        self.assertEqual(waiting["dimensions"]["design"]["severity"], "blocked")
        self.assertEqual(resolved["dimensions"]["design"]["state"], "resolved")
        self.assertEqual(reopened["dimensions"]["design"]["state"], "reopened")
        self.assertEqual(len(reopened["dimensions"]["design"]["history"]), 3)
        self.assertEqual(reopened["summary"]["state"], "needs_attention")


class TestWorkflowBriefingRoutes(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.objectives_dir = Path(self.tmpdir.name) / "objectives"
        self.workspaces_dir = Path(self.tmpdir.name) / "workspaces"
        self.patch_objectives_dir = patch.object(objectives, "OBJECTIVES_DIR", self.objectives_dir)
        self.patch_workspaces_dir = patch.object(workspaces, "WORKSPACES_DIR", self.workspaces_dir)
        self.patch_objectives_dir.start()
        self.patch_workspaces_dir.start()
        self.addCleanup(self.patch_objectives_dir.stop)
        self.addCleanup(self.patch_workspaces_dir.stop)
        self.patch_jira = patch.object(workflow, "fetch_assigned_jira")
        self.mock_fetch_jira = self.patch_jira.start()
        self.mock_fetch_jira.return_value = {"ok": True, "tickets": [], "error": None}
        self.addCleanup(self.patch_jira.stop)

    def _write_objective(self, objective_id="obj-brief", **overrides):
        objective_dir = self.objectives_dir / objective_id
        objective_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "id": objective_id,
            "goal": "Ship concise briefings",
            "status": "running",
            "projectDir": self.tmpdir.name,
            "baseBranch": "main",
            "tasks": [],
            "workflowMode": "structured",
            "createdAt": "2026-05-10T00:00:00+00:00",
            "updatedAt": "2026-05-10T00:00:00+00:00",
        }
        payload.update(overrides)
        (objective_dir / "objective.json").write_text(json.dumps(payload), encoding="utf-8")
        return payload

    def test_briefing_prioritizes_decisions_context_and_watchlist(self):
        self._write_objective()
        workflow.update_context_dimension("obj-brief", "backend", {"state": "needed", "required": True, "reason": "Need API owner."})
        decision = workflow.create_decision({"title": "Approve API contract", "recommendation": "Ship the briefing endpoint."})
        workflow.create_checkin({"summary": "Manual check complete", "health": "green"})

        briefing = workflow.briefing_payload()

        self.assertTrue(briefing["ok"])
        self.assertIn("need Ronnie", briefing["headline"])
        self.assertEqual(briefing["counts"]["decisions"], 1)
        self.assertEqual(briefing["counts"]["needsRonnie"], 2)
        self.assertEqual(briefing["nextActions"][0]["kind"], "decision")
        self.assertEqual(briefing["nextActions"][0]["target"]["id"], decision["id"])
        self.assertEqual(briefing["nextActions"][1]["kind"], "context")
        self.assertEqual(briefing["watchlist"][0]["id"], "obj-brief")
        self.assertEqual(briefing["recentCheckIns"][0]["summary"], "Manual check complete")

    def test_briefing_recommends_idea_grooming_when_nothing_is_blocked(self):
        idea = workflow.create_idea({"title": "Capture rough work"})

        briefing = workflow.briefing_payload()

        self.assertEqual(briefing["counts"]["needsRonnie"], 0)
        self.assertEqual(briefing["nextActions"][0]["kind"], "idea")
        self.assertEqual(briefing["nextActions"][0]["target"]["id"], idea["id"])


if __name__ == "__main__":
    unittest.main()
