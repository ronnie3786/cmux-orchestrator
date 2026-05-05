import json
import unittest

from cmux_harness.demo import DemoHarness


class TestDemoHarness(unittest.TestCase):
    def setUp(self):
        self.demo = DemoHarness()

    def _json(self, method, path, query="", payload=None, headers=None, raw_body=None):
        body = raw_body
        if body is None:
            body = json.dumps(payload or {}).encode("utf-8") if payload is not None else b""
        status, response = self.demo.handle_json(
            method,
            path,
            query=query,
            headers=headers or {},
            body=body,
        )
        return status, response

    def test_status_matches_ios_contract(self):
        status, response = self._json("GET", "/api/status")

        self.assertEqual(status, 200)
        self.assertTrue(response["enabled"])
        self.assertTrue(response["socketFound"])
        self.assertTrue(response["connected"])
        self.assertGreaterEqual(len(response["workspaces"]), 3)
        workspace = response["workspaces"][0]
        self.assertIn("hasClaude", workspace)
        self.assertIn("screenTail", workspace)
        self.assertIn("surfaceId", workspace)

    def test_namespaced_api_paths_have_isolated_state(self):
        self._json(
            "POST",
            "/review-a/api/rename",
            payload={"index": 0, "name": "Namespace A"},
        )

        _, default_status = self._json("GET", "/api/status")
        _, namespaced_status = self._json("GET", "/review-a/api/status")

        self.assertEqual(default_status["workspaces"][0]["customName"], "Review landing polish")
        self.assertEqual(namespaced_status["workspaces"][0]["customName"], "Namespace A")

    def test_send_updates_terminal_and_clears_latest_waiting_signal(self):
        _, before_log = self._json("GET", "/api/log")
        self.assertEqual(before_log[0]["workspace"], 2)
        self.assertIn("human", before_log[0]["action"].lower())

        status, response = self._json(
            "POST",
            "/api/send",
            payload={"index": 2, "text": "Use the public demo server\n", "surfaceId": "surface-2"},
        )
        self.assertEqual(status, 200)
        self.assertTrue(response["ok"])

        _, after_log = self._json("GET", "/api/log")
        self.assertEqual(after_log[0]["workspace"], 2)
        self.assertEqual(after_log[0]["action"], "user input")

        _, screen = self._json("GET", "/api/screen", query="index=2&lines=80")
        self.assertIn("Use the public demo server", screen["screen"])
        self.assertIn("Demo agent received", screen["screen"])

    def test_new_session_creates_mutable_workspace(self):
        status, response = self._json(
            "POST",
            "/api/new-session",
            payload={
                "projectPath": "/Users/demo/Code/cmux-harness",
                "branchName": "feature/apple-review",
                "jiraUrl": "HARNESS-101",
                "prompt": "Prepare external TestFlight review.",
                "command": "claude",
                "sessionName": "Apple Review Dry Run",
            },
        )

        self.assertEqual(status, 200)
        self.assertTrue(response["ok"])
        self.assertEqual(response["workspace"]["index"], 4)

        _, status_response = self._json("GET", "/api/status")
        self.assertEqual(status_response["workspaces"][-1]["customName"], "Apple Review Dry Run")

    def test_git_stage_unstage_and_diff(self):
        status, response = self._json(
            "POST",
            "/api/git-stage",
            payload={"index": 1, "file": "cmux_harness/demo.py"},
        )
        self.assertEqual(status, 200)
        self.assertTrue(response["ok"])

        _, git_status = self._json("GET", "/api/git-status", query="index=1")
        self.assertIn({"status": "A", "file": "cmux_harness/demo.py"}, git_status["staged"])
        self.assertNotIn({"status": "M", "file": "cmux_harness/demo.py"}, git_status["unstaged"])

        status, diff = self._json(
            "POST",
            "/api/git-diff",
            payload={"index": 1, "file": "cmux_harness/demo.py", "section": "staged"},
        )
        self.assertEqual(status, 200)
        self.assertTrue(diff["ok"])
        self.assertIn("diff --git", diff["diff"])

    def test_attachments_return_ios_upload_shape(self):
        status, response = self._json(
            "POST",
            "/api/attachments",
            headers={
                "X-Cmux-Workspace-Index": "0",
                "X-Cmux-Workspace-UUID": "workspace-0",
                "X-Cmux-Filename": "note.txt",
                "Content-Type": "text/plain",
            },
            raw_body=b"hello",
        )

        self.assertEqual(status, 200)
        self.assertTrue(response["ok"])
        self.assertEqual(response["attachment"]["originalFilename"], "note.txt")
        self.assertEqual(response["attachment"]["size"], 5)


if __name__ == "__main__":
    unittest.main()
