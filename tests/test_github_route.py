import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from cmux_harness.routes import github


class TestGitHubRoute(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.repo_path = Path(self.tmpdir.name) / "repo"
        self.repo_path.mkdir()
        source_dir = self.repo_path / "Sources"
        source_dir.mkdir()
        (source_dir / "App.swift").write_text(
            "\n".join(f"let value{line} = {line}" for line in range(1, 41)) + "\n",
            encoding="utf-8",
        )

    def test_fetch_pr_review_threads_hides_resolved_threads_by_default(self):
        pr_payload = {
            "number": 42,
            "title": "Ship comments",
            "url": "https://github.com/doximity/cmux-harness/pull/42",
            "headRefName": "feature/pr-comments",
            "baseRefName": "main",
            "state": "OPEN",
            "author": {"login": "reviewer"},
        }
        graphql_payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [
                                self._thread("thread-1", "Sources/App.swift", 18, False, "Use the new helper."),
                                self._thread("thread-2", "Sources/App.swift", 24, True, "Already fixed."),
                            ],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    }
                }
            }
        }

        with patch("cmux_harness.routes.github.subprocess.run") as mock_run:
            mock_run.side_effect = [
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(pr_payload), stderr=""),
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(graphql_payload), stderr=""),
            ]

            response = github.fetch_pr_review_threads(str(self.repo_path))

        self.assertEqual(response["pullRequest"]["number"], 42)
        self.assertEqual(response["repository"]["owner"], "doximity")
        self.assertEqual(response["repository"]["name"], "cmux-harness")
        self.assertEqual(response["totalThreadCount"], 2)
        self.assertEqual(response["returnedThreadCount"], 1)
        self.assertEqual(response["hiddenResolvedCount"], 1)
        self.assertEqual(response["threads"][0]["id"], "thread-1")
        self.assertEqual(response["threads"][0]["comments"][0]["body"], "Use the new helper.")
        self.assertEqual(response["threads"][0]["codeContext"]["source"], "workspace")
        self.assertEqual(response["threads"][0]["codeContext"]["startLine"], 18)
        self.assertEqual(response["threads"][0]["codeContext"]["endLine"], 18)
        self.assertEqual(
            [line["number"] for line in response["threads"][0]["codeContext"]["lines"]],
            [16, 17, 18, 19, 20],
        )
        self.assertEqual(response["threads"][0]["codeContext"]["lines"][2]["text"], "let value18 = 18")
        self.assertTrue(response["threads"][0]["codeContext"]["lines"][2]["isTarget"])
        self.assertEqual(response["files"][0]["path"], "Sources/App.swift")
        self.assertEqual(response["files"][0]["threadCount"], 1)
        self.assertEqual(mock_run.call_args_list[0].args[0][:3], ["gh", "pr", "view"])
        self.assertEqual(mock_run.call_args_list[1].args[0][:3], ["gh", "api", "graphql"])

    def test_fetch_pr_review_threads_falls_back_to_diff_hunk_code_context(self):
        pr_payload = {
            "number": 42,
            "title": "Ship comments",
            "url": "https://github.com/doximity/cmux-harness/pull/42",
        }
        graphql_payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [
                                self._thread(
                                    "thread-1",
                                    "Sources/Missing.swift",
                                    18,
                                    False,
                                    "Use the new helper.",
                                    diff_hunk=(
                                        "@@ -16,4 +16,5 @@\n"
                                        " let value16 = 16\n"
                                        " let value17 = 17\n"
                                        "+let value18 = helper()\n"
                                        " let value19 = 19"
                                    ),
                                ),
                            ],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    }
                }
            }
        }

        with patch("cmux_harness.routes.github.subprocess.run") as mock_run:
            mock_run.side_effect = [
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(pr_payload), stderr=""),
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(graphql_payload), stderr=""),
            ]

            response = github.fetch_pr_review_threads(str(self.repo_path))

        self.assertEqual(response["threads"][0]["codeContext"]["source"], "diffHunk")
        self.assertEqual(response["threads"][0]["codeContext"]["lines"][2]["number"], 18)
        self.assertEqual(response["threads"][0]["codeContext"]["lines"][2]["text"], "let value18 = helper()")
        self.assertTrue(response["threads"][0]["codeContext"]["lines"][2]["isTarget"])

    def test_fetch_pr_review_threads_can_include_resolved_threads(self):
        pr_payload = {
            "number": 42,
            "title": "Ship comments",
            "url": "https://github.com/doximity/cmux-harness/pull/42",
        }
        graphql_payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [
                                self._thread("thread-1", "Sources/App.swift", 18, False, "Use the new helper."),
                                self._thread("thread-2", "Sources/App.swift", 24, True, "Already fixed."),
                            ],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    }
                }
            }
        }

        with patch("cmux_harness.routes.github.subprocess.run") as mock_run:
            mock_run.side_effect = [
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(pr_payload), stderr=""),
                subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(graphql_payload), stderr=""),
            ]

            response = github.fetch_pr_review_threads(str(self.repo_path), include_resolved=True)

        self.assertEqual(response["returnedThreadCount"], 2)
        self.assertEqual(response["hiddenResolvedCount"], 0)
        self.assertEqual([thread["id"] for thread in response["threads"]], ["thread-1", "thread-2"])

    def test_fetch_pr_review_threads_rejects_non_github_dot_com_pull_requests(self):
        pr_payload = {
            "number": 42,
            "title": "Ship comments",
            "url": "https://github.example.com/doximity/cmux-harness/pull/42",
        }

        with patch("cmux_harness.routes.github.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps(pr_payload),
                stderr="",
            )

            with self.assertRaises(github.GitHubRouteError) as context:
                github.fetch_pr_review_threads(str(self.repo_path))

        self.assertEqual(context.exception.status, 400)
        self.assertIn("github.com", str(context.exception))

    def test_no_pr_for_branch_returns_404(self):
        with patch("cmux_harness.routes.github.subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                args=[],
                returncode=1,
                stdout="",
                stderr="no pull requests found for branch",
            )

            with self.assertRaises(github.GitHubRouteError) as context:
                github.fetch_pr_review_threads(str(self.repo_path))

        self.assertEqual(context.exception.status, 404)
        self.assertEqual(str(context.exception), "No GitHub pull request found for the current branch")

    def test_handle_get_pr_comments_requires_index_or_path(self):
        handler = Mock()
        handler.parse_qs.return_value = {}
        handler._json_response = Mock()
        parsed = Mock(query="")

        github.handle_get_pr_comments(handler, parsed, engine=Mock())

        handler._json_response.assert_called_once_with(
            {"ok": False, "error": "index or path required"},
            400,
        )

    def _thread(self, thread_id, path, line, resolved, body, diff_hunk="@@ -1 +1 @@"):
        return {
            "id": thread_id,
            "isResolved": resolved,
            "isOutdated": False,
            "path": path,
            "line": line,
            "originalLine": line,
            "startLine": None,
            "originalStartLine": None,
            "diffSide": "RIGHT",
            "startDiffSide": None,
            "subjectType": "LINE",
            "comments": {
                "nodes": [
                    {
                        "id": f"{thread_id}-comment",
                        "author": {"login": "octocat"},
                        "body": body,
                        "bodyText": body,
                        "createdAt": "2026-04-29T12:00:00Z",
                        "updatedAt": "2026-04-29T12:00:00Z",
                        "url": f"https://github.com/doximity/cmux-harness/pull/42#discussion_r{line}",
                        "diffHunk": diff_hunk,
                        "path": path,
                        "line": line,
                        "originalLine": line,
                    }
                ]
            },
        }
