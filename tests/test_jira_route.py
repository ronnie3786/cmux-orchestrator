import json
import subprocess
import unittest
from unittest.mock import patch

from cmux_harness.routes import jira


class TestJiraRoute(unittest.TestCase):
    def test_build_assigned_jql_defaults_to_all_assigned_active_work(self):
        self.assertEqual(
            jira.build_assigned_jql(),
            'assignee = currentUser() AND (statusCategory = "In Progress" OR status = "Selected for Development") ORDER BY updated DESC',
        )

    def test_build_assigned_jql_can_filter_to_project(self):
        self.assertEqual(
            jira.build_assigned_jql("IOSDOX"),
            'assignee = currentUser() AND project = IOSDOX AND (statusCategory = "In Progress" OR status = "Selected for Development") ORDER BY updated DESC',
        )

    def test_build_assigned_jql_rejects_invalid_project(self):
        with self.assertRaises(jira.JiraRouteError) as context:
            jira.build_assigned_jql('IOSDOX OR status != "Done"')

        self.assertEqual(context.exception.status, 400)

    def test_normalize_workitems_sorts_by_key_and_maps_fields(self):
        workitems = [
            {
                "key": "IOSDOX-25867",
                "fields": {
                    "summary": "GPT - Update labels",
                    "status": {"name": "In Progress"},
                    "priority": {"name": "Not Selected"},
                    "issuetype": {"name": "Story"},
                },
            },
            {
                "key": "IOSDOX-24739",
                "fields": {
                    "summary": "Improve TestRail Sync Skill",
                    "status": {"name": "In QA"},
                    "priority": {"name": "Low"},
                    "issuetype": {"name": "Story"},
                },
            },
        ]

        tickets = jira.normalize_workitems(workitems, site="https://doximity.atlassian.net/")

        self.assertEqual([ticket["key"] for ticket in tickets], ["IOSDOX-24739", "IOSDOX-25867"])
        self.assertEqual(tickets[0]["title"], "Improve TestRail Sync Skill")
        self.assertEqual(tickets[0]["status"], "In QA")
        self.assertEqual(tickets[0]["priority"], "Low")
        self.assertEqual(tickets[0]["issueType"], "Story")
        self.assertEqual(tickets[0]["projectKey"], "IOSDOX")
        self.assertEqual(tickets[0]["url"], "https://doximity.atlassian.net/browse/IOSDOX-24739")

    def test_ticket_projects_returns_sorted_project_keys(self):
        tickets = [
            {"projectKey": "FINDER"},
            {"projectKey": "IOSDOX"},
            {"projectKey": "FINDER"},
            {"projectKey": ""},
        ]

        self.assertEqual(jira.ticket_projects(tickets), ["FINDER", "IOSDOX"])

    def test_fetch_assigned_tickets_uses_acli_json_output_without_default_project_filter(self):
        payload = [
            {
                "key": "IOSDOX-25867",
                "fields": {
                    "summary": "GPT - Update labels",
                    "status": {"name": "In Progress"},
                    "priority": {"name": "Not Selected"},
                    "issuetype": {"name": "Story"},
                },
            }
        ]
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(payload),
            stderr="",
        )

        with patch("cmux_harness.routes.jira.subprocess.run", return_value=completed) as mock_run:
            tickets = jira.fetch_assigned_tickets(limit=12, site="doximity.atlassian.net")

        self.assertEqual(tickets[0]["key"], "IOSDOX-25867")
        args = mock_run.call_args.args[0]
        command_text = " ".join(args)
        self.assertEqual(args[:4], ["acli", "jira", "workitem", "search"])
        self.assertIn('assignee = currentUser() AND (statusCategory = "In Progress"', command_text)
        self.assertNotIn("project = IOSDOX", command_text)
        self.assertIn("--json", args)
        self.assertIn("--limit", args)
        self.assertIn("12", args)

    def test_fetch_assigned_tickets_surfaces_acli_error(self):
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="unauthorized: use 'acli jira auth login' to authenticate",
        )

        with patch("cmux_harness.routes.jira.subprocess.run", return_value=completed):
            with self.assertRaises(jira.JiraRouteError) as context:
                jira.fetch_assigned_tickets(project="IOSDOX")

        self.assertEqual(context.exception.status, 502)
        self.assertIn("unauthorized", str(context.exception))

    def test_extract_jira_key_accepts_key_or_browse_url(self):
        self.assertEqual(jira.extract_jira_key("iosdox-123"), "IOSDOX-123")
        self.assertEqual(
            jira.extract_jira_key("https://doximity.atlassian.net/browse/finder_qa-987?x=1"),
            "FINDER_QA-987",
        )
        self.assertIsNone(jira.extract_jira_key("not a ticket"))

    def test_fetch_ticket_looks_up_exact_key(self):
        payload = [
            {
                "key": "FINDER-42",
                "fields": {
                    "summary": "Lookup any board",
                    "status": {"name": "Selected for Development"},
                    "priority": {"name": "High"},
                    "issuetype": {"name": "Bug"},
                },
            }
        ]
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(payload),
            stderr="",
        )

        with patch("cmux_harness.routes.jira.subprocess.run", return_value=completed) as mock_run:
            ticket = jira.fetch_ticket(key="finder-42")

        self.assertEqual(ticket["key"], "FINDER-42")
        self.assertEqual(ticket["projectKey"], "FINDER")
        args = mock_run.call_args.args[0]
        self.assertIn("key = FINDER-42", " ".join(args))
        self.assertIn("1", args)


if __name__ == "__main__":
    unittest.main()
