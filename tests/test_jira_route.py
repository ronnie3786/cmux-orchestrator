import json
import subprocess
import tempfile
import unittest
from pathlib import Path
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
            jira.build_assigned_jql("APP"),
            'assignee = currentUser() AND project = APP AND (statusCategory = "In Progress" OR status = "Selected for Development") ORDER BY updated DESC',
        )

    def test_build_assigned_jql_rejects_invalid_project(self):
        with self.assertRaises(jira.JiraRouteError) as context:
            jira.build_assigned_jql('APP OR status != "Done"')

        self.assertEqual(context.exception.status, 400)

    def test_normalize_workitems_sorts_by_key_and_maps_fields(self):
        blocked_marker = "".join(("G", "P", "T"))
        workitems = [
            {
                "key": "APP-25867",
                "fields": {
                    "summary": "Update settings labels",
                    "status": {"name": "In Progress"},
                    "priority": {"name": "Not Selected"},
                    "issuetype": {"name": "Story"},
                },
            },
            {
                "key": "APP-24739",
                "fields": {
                    "summary": f"{blocked_marker} - Improve TestRail Sync Skill",
                    "status": {"name": "In QA"},
                    "priority": {"name": "Low"},
                    "issuetype": {"name": "Story"},
                },
            },
        ]

        tickets = jira.normalize_workitems(workitems, site="https://example.atlassian.net/")

        self.assertEqual([ticket["key"] for ticket in tickets], ["APP-24739", "APP-25867"])
        self.assertEqual(tickets[0]["title"], "Improve TestRail Sync Skill")
        self.assertEqual(tickets[0]["status"], "In QA")
        self.assertEqual(tickets[0]["priority"], "Low")
        self.assertEqual(tickets[0]["issueType"], "Story")
        self.assertEqual(tickets[0]["projectKey"], "APP")
        self.assertEqual(tickets[0]["url"], "https://example.atlassian.net/browse/APP-24739")

    def test_ticket_projects_returns_sorted_project_keys(self):
        tickets = [
            {"projectKey": "WEB"},
            {"projectKey": "APP"},
            {"projectKey": "WEB"},
            {"projectKey": ""},
        ]

        self.assertEqual(jira.ticket_projects(tickets), ["APP", "WEB"])

    def test_default_jira_site_reads_active_acli_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_dir = Path(tmp) / ".config" / "acli"
            config_dir.mkdir(parents=True)
            (config_dir / "jira_config.yaml").write_text(
                "version: 1\nprofiles:\n    - site: doximity.atlassian.net\n      auth_type: oauth\n",
                encoding="utf-8",
            )

            with patch("cmux_harness.routes.jira.Path.home", return_value=Path(tmp)), \
                    patch.dict("cmux_harness.routes.jira.os.environ", {}, clear=True):
                self.assertEqual(jira.default_jira_site(), "doximity.atlassian.net")
                tickets = jira.normalize_workitems([{
                    "key": "IOSDOX-26059",
                    "fields": {"summary": "Recorder bug"},
                }])

        self.assertEqual(tickets[0]["url"], "https://doximity.atlassian.net/browse/IOSDOX-26059")

    def test_default_jira_site_allows_env_override(self):
        with patch.dict("cmux_harness.routes.jira.os.environ", {"CMUX_JIRA_SITE": "https://override.atlassian.net/"}, clear=True):
            self.assertEqual(jira.default_jira_site(), "override.atlassian.net")

    def test_fetch_assigned_tickets_uses_acli_json_output_without_default_project_filter(self):
        payload = [
            {
                "key": "APP-25867",
                "fields": {
                    "summary": "Update settings labels",
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
            tickets = jira.fetch_assigned_tickets(limit=12, site="example.atlassian.net")

        self.assertEqual(tickets[0]["key"], "APP-25867")
        args = mock_run.call_args.args[0]
        command_text = " ".join(args)
        self.assertEqual(args[:4], ["acli", "jira", "workitem", "search"])
        self.assertIn('assignee = currentUser() AND (statusCategory = "In Progress"', command_text)
        self.assertNotIn("project = APP", command_text)
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
                jira.fetch_assigned_tickets(project="APP")

        self.assertEqual(context.exception.status, 502)
        self.assertIn("unauthorized", str(context.exception))

    def test_extract_jira_key_accepts_key_or_browse_url(self):
        self.assertEqual(jira.extract_jira_key("app-123"), "APP-123")
        self.assertEqual(
            jira.extract_jira_key("https://example.atlassian.net/browse/web_qa-987?x=1"),
            "WEB_QA-987",
        )
        self.assertIsNone(jira.extract_jira_key("not a ticket"))

    def test_fetch_ticket_looks_up_exact_key(self):
        payload = [
            {
                "key": "WEB-42",
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
            ticket = jira.fetch_ticket(key="web-42")

        self.assertEqual(ticket["key"], "WEB-42")
        self.assertEqual(ticket["projectKey"], "WEB")
        args = mock_run.call_args.args[0]
        self.assertIn("key = WEB-42", " ".join(args))
        self.assertIn("1", args)


if __name__ == "__main__":
    unittest.main()
