import io
import json
import os
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest.mock import patch

from herdr_harness import cmux_tools


class _Response:
    def __init__(self, body=b'{"ok":true}', *, status=200, headers=None):
        self._stream = io.BytesIO(body)
        self.status = status
        self.headers = dict(headers or {})

    def read(self, size=-1):
        return self._stream.read(size)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


def _json_response(payload, *, status=200, headers=None):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    values = {"Content-Type": "application/json", **(headers or {})}
    return _Response(body, status=status, headers=values)


def _headers(request):
    return {key.lower(): value for key, value in request.header_items()}


class CmuxToolsConfigurationTests(unittest.TestCase):
    def test_base_url_uses_environment_and_strips_terminal_harness_path(self):
        default = cmux_tools.CmuxToolsClient(environ={})
        direct = cmux_tools.CmuxToolsClient(
            environ={"HERDR_HARNESS_CMUX_URL": "http://100.124.17.108:9091/harness/"}
        )
        explicit = cmux_tools.CmuxToolsClient(
            environ={"HERDR_HARNESS_CMUX_URL": "http://ignored.example:1"},
            base_url="http://cmux.example:9091/harness",
        )

        self.assertEqual(default.base_url, "http://127.0.0.1:9091")
        self.assertEqual(direct.base_url, "http://100.124.17.108:9091")
        self.assertEqual(explicit.base_url, "http://cmux.example:9091")

    def test_base_url_rejects_unsafe_or_ambiguous_values(self):
        values = (
            "cmux.example:9091",
            "ftp://cmux.example/tools",
            "http://user:password@cmux.example:9091",
            "http://cmux.example:9091?token=secret",
            "http://cmux.example:9091/#fragment",
            "http://[not-an-ipv6-address]:9091",
        )

        for value in values:
            with self.subTest(value=value), self.assertRaises(ValueError):
                cmux_tools.CmuxToolsClient(base_url=value)

    def test_transport_bounds_are_validated_at_construction(self):
        for timeout in (0, 0.09, 121, "not-a-number"):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                cmux_tools.CmuxToolsClient(timeout=timeout)
        for maximum in (1023, 16 * 1024 * 1024 + 1, "not-an-integer"):
            with self.subTest(maximum=maximum), self.assertRaises(ValueError):
                cmux_tools.CmuxToolsClient(max_response_bytes=maximum)


class CmuxToolsContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "workspace with spaces"
        self.root.mkdir()
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.requests = []

    def _open(self, request, timeout):
        self.requests.append((request, timeout))
        return _json_response(
            {
                "ok": True,
                "cwd": str(self.root.resolve()),
                "branch": "main",
                "staged": [],
                "unstaged": [],
                "untracked": [],
                "commits": [],
                "diff": "",
                "rootPath": str(self.root.resolve()),
                "skillsDirectory": ".claude/skills",
                "userSkillsDirectory": "~/.claude/skills",
                "projectSkills": [],
                "userSkills": [],
                "skills": [],
                "query": "Pane Detail",
                "files": [],
                "truncated": False,
                "limit": 37,
                "project": "IOSDOX",
                "projects": ["IOSDOX"],
                "site": "jira.example.test",
                "tickets": [],
                "ticket": {
                    "key": "IOSDOX-42",
                    "projectKey": "IOSDOX",
                    "title": "Wire cmux",
                    "status": "In Progress",
                    "priority": "High",
                    "issueType": "Story",
                    "url": "https://jira.example.test/browse/IOSDOX-42",
                },
            }
        )

    @staticmethod
    def _request_parts(request):
        parsed = urllib.parse.urlsplit(request.full_url)
        return parsed.path, urllib.parse.parse_qs(parsed.query)

    def test_git_skills_files_and_jira_use_exact_cmux_path_contracts(self):
        client = cmux_tools.CmuxToolsClient(
            base_url="http://cmux.example:9091/harness",
            timeout=7.5,
        )
        file = "Sources/Pane Detail.swift"

        with patch("herdr_harness.cmux_tools._open_no_redirect", side_effect=self._open):
            client.git_status(self.root)
            client.git_diff(self.root, file, "staged")
            staged = client.git_stage(self.root, file)
            unstaged = client.git_unstage(self.root, file)
            client.skills(self.root)
            client.search_files(self.root, "Pane Detail", limit=37)
            client.jira_assigned(project="iosdox", limit=12)
            client.jira_issue("  IOSDOX-42  ")

        root = str(self.root.resolve())
        expected = [
            ("GET", "/api/git-status-path", {"path": [root]}, None),
            (
                "POST",
                "/api/git-diff-path",
                {},
                {"path": root, "file": file, "section": "staged"},
            ),
            ("POST", "/api/git-stage-path", {}, {"path": root, "file": file}),
            ("POST", "/api/git-unstage-path", {}, {"path": root, "file": file}),
            ("GET", "/api/skills", {"path": [root]}, None),
            (
                "GET",
                "/api/file-search",
                {"path": [root], "q": ["Pane Detail"], "limit": ["37"]},
                None,
            ),
            (
                "GET",
                "/api/jira/assigned",
                {"limit": ["12"], "project": ["IOSDOX"]},
                None,
            ),
            ("GET", "/api/jira/issue", {"q": ["IOSDOX-42"]}, None),
        ]

        self.assertEqual(len(self.requests), len(expected))
        expected_timeouts = [10.0] * 4 + [15.0] * 4
        for (request, timeout), (method, path, query, body), expected_timeout in zip(
            self.requests,
            expected,
            expected_timeouts,
        ):
            with self.subTest(path=path):
                actual_path, actual_query = self._request_parts(request)
                self.assertEqual(request.method, method)
                self.assertEqual(actual_path, path)
                self.assertEqual(actual_query, query)
                self.assertEqual(
                    json.loads(request.data.decode("utf-8")) if request.data else None,
                    body,
                )
                headers = _headers(request)
                self.assertEqual(headers["accept"], "application/json")
                self.assertNotIn("authorization", headers)
                self.assertEqual(timeout, expected_timeout)
                if body is not None:
                    self.assertEqual(headers["content-type"], "application/json")

        self.assertTrue(staged["ok"])
        self.assertTrue(unstaged["ok"])

    def test_nested_pane_cwd_uses_git_root_only_for_git_operations(self):
        nested = self.root / "Sources" / "Features"
        nested.mkdir(parents=True)
        client = cmux_tools.CmuxToolsClient(timeout=1)

        with patch(
            "herdr_harness.cmux_tools._open_no_redirect",
            side_effect=self._open,
        ):
            client.git_status(nested)
            client.git_diff(nested, "Sources/Pane.swift", "unstaged")
            client.skills(nested)
            client.search_files(nested, "Pane")

        repository_root = str(self.root.resolve())
        nested_root = str(nested.resolve())
        status_request, diff_request, skills_request, files_request = self.requests
        self.assertEqual(
            self._request_parts(status_request[0])[1],
            {"path": [repository_root]},
        )
        self.assertEqual(
            json.loads(diff_request[0].data),
            {
                "path": repository_root,
                "file": "Sources/Pane.swift",
                "section": "unstaged",
            },
        )
        self.assertEqual(
            self._request_parts(skills_request[0])[1],
            {"path": [nested_root]},
        )
        self.assertEqual(
            self._request_parts(files_request[0])[1]["path"],
            [nested_root],
        )
        self.assertEqual(
            [item[1] for item in self.requests],
            [10.0, 10.0, 15.0, 15.0],
        )

    def test_git_requires_a_repository_before_contacting_cmux(self):
        outside_repository = Path(self.temporary.name) / "not-a-repository"
        outside_repository.mkdir()
        client = cmux_tools.CmuxToolsClient()

        with patch("herdr_harness.cmux_tools._open_no_redirect") as opened:
            with self.assertRaises(cmux_tools.CmuxToolsError) as error:
                client.git_status(outside_repository)

        self.assertEqual(error.exception.code, "git_repository_not_found")
        self.assertEqual(error.exception.status, 404)
        opened.assert_not_called()

    def test_optional_base_path_is_preserved_when_harness_suffix_is_removed(self):
        client = cmux_tools.CmuxToolsClient(
            base_url="http://cmux.example:9091/gateway/harness"
        )
        with patch(
            "herdr_harness.cmux_tools._open_no_redirect",
            side_effect=self._open,
        ):
            client.jira_assigned()

        path, query = self._request_parts(self.requests[0][0])
        self.assertEqual(path, "/gateway/api/jira/assigned")
        self.assertEqual(query, {"limit": ["50"]})

    def test_git_file_validation_blocks_traversal_absolute_and_parent_symlink_escape(self):
        outside = Path(self.temporary.name) / "secret.txt"
        outside.write_text("secret", encoding="utf-8")
        outside_directory = Path(self.temporary.name) / "outside-directory"
        outside_directory.mkdir()
        (self.root / "outside-directory-link").symlink_to(outside_directory)
        client = cmux_tools.CmuxToolsClient()
        invalid_paths = (
            "",
            "../secret.txt",
            str(outside),
            "outside-directory-link/secret.txt",
            "bad\x00name",
        )

        with patch("herdr_harness.cmux_tools._open_no_redirect") as opened:
            for value in invalid_paths:
                with self.subTest(value=value), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                    client.git_stage(self.root, value)
                self.assertEqual(error.exception.code, "invalid_git_path")
                self.assertEqual(error.exception.status, 400)

            with self.assertRaises(cmux_tools.CmuxToolsError) as error:
                client.git_diff(self.root, "Sources/Pane.swift", "working-tree")
            self.assertEqual(error.exception.code, "invalid_git_section")
            self.assertEqual(error.exception.status, 400)
            opened.assert_not_called()

    def test_git_file_validation_allows_final_symlink_pathname(self):
        outside = Path(self.temporary.name) / "secret.txt"
        outside.write_text("secret", encoding="utf-8")
        (self.root / "outside-link").symlink_to(outside)
        client = cmux_tools.CmuxToolsClient()

        with patch(
            "herdr_harness.cmux_tools._open_no_redirect",
            side_effect=self._open,
        ):
            response = client.git_stage(self.root, "outside-link")

        self.assertTrue(response["ok"])
        self.assertEqual(
            json.loads(self.requests[0][0].data),
            {
                "path": str(self.root.resolve()),
                "file": "outside-link",
            },
        )

    def test_queries_and_limits_are_rejected_before_network_access(self):
        client = cmux_tools.CmuxToolsClient()
        invalid_calls = (
            lambda: client.search_files(self.root, "bad\x00query", 10),
            lambda: client.search_files(self.root, "query", 0),
            lambda: client.search_files(self.root, "query", 501),
            lambda: client.jira_assigned("BAD;DROP", 10),
            lambda: client.jira_assigned("IOSDOX", 101),
            lambda: client.jira_issue(""),
        )

        with patch("herdr_harness.cmux_tools._open_no_redirect") as opened:
            for operation in invalid_calls:
                with self.subTest(operation=operation), self.assertRaises(cmux_tools.CmuxToolsError):
                    operation()
            opened.assert_not_called()

    def test_each_route_rejects_malformed_success_payloads(self):
        client = cmux_tools.CmuxToolsClient()
        root = str(self.root.resolve())
        ticket = {
            "key": "IOSDOX-42",
            "projectKey": "IOSDOX",
            "title": "Wire cmux",
            "status": "In Progress",
            "priority": "High",
            "issueType": "Story",
            "url": "https://jira.example.test/browse/IOSDOX-42",
        }
        cases = (
            (
                "git-status",
                lambda: client.git_status(self.root),
                {
                    "ok": True,
                    "cwd": root,
                    "branch": "main",
                    "staged": [],
                    "unstaged": [],
                    "untracked": [],
                    "commits": "not-an-array",
                },
            ),
            (
                "git-diff",
                lambda: client.git_diff(self.root, "Pane.swift", "unstaged"),
                {"ok": True, "diff": 42},
            ),
            (
                "git-stage",
                lambda: client.git_stage(self.root, "Pane.swift"),
                {"file": "Pane.swift"},
            ),
            (
                "git-unstage",
                lambda: client.git_unstage(self.root, "Pane.swift"),
                {"ok": "true"},
            ),
            (
                "skills",
                lambda: client.skills(self.root),
                {"ok": True, "projectSkills": [{"name": "missing-path"}]},
            ),
            (
                "files",
                lambda: client.search_files(self.root, "Pane"),
                {"ok": True, "query": "Pane", "files": [{"path": 42}]},
            ),
            (
                "jira-assigned",
                lambda: client.jira_assigned(),
                {"ok": True, "tickets": [{"key": "IOSDOX-42"}]},
            ),
            (
                "jira-issue",
                lambda: client.jira_issue("IOSDOX-42"),
                {
                    "ok": True,
                    "ticket": {key: value for key, value in ticket.items() if key != "issueType"},
                },
            ),
            (
                "attachment-workspace-status",
                lambda: client.attachment_workspace_identity(self.root),
                {"workspaces": [{"cwd": root, "uuid": "w1", "index": "23"}]},
            ),
            (
                "attachment-upload",
                lambda: client.upload_attachment(
                    workspace_uuid="w1",
                    workspace_index=23,
                    filename="note.txt",
                    content_type="text/plain",
                    data=b"x",
                ),
                {"ok": True, "attachment": {"id": "attachment-1"}},
            ),
        )

        for route, operation, payload in cases:
            with self.subTest(route=route), patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                return_value=_json_response(payload),
            ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                operation()
            self.assertEqual(error.exception.code, "cmux_invalid_response")
            self.assertEqual(error.exception.status, 502)
            self.assertEqual(error.exception.upstream_status, 200)


class CmuxToolsTransportTests(unittest.TestCase):
    def test_response_size_is_bounded_with_and_without_content_length(self):
        client = cmux_tools.CmuxToolsClient(max_response_bytes=1024)
        responses = (
            _Response(b"{}", headers={"Content-Length": "1025"}),
            _Response(b"x" * 1025),
        )

        for response in responses:
            with self.subTest(headers=response.headers), patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                return_value=response,
            ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                client.jira_assigned()
            self.assertEqual(error.exception.code, "cmux_response_too_large")
            self.assertEqual(error.exception.status, 502)

    def test_invalid_json_and_non_object_responses_are_typed(self):
        responses = (_Response(b"not-json"), _Response(b"[]"), _Response(b"\xff"))

        for response in responses:
            with self.subTest(body=response), patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                return_value=response,
            ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                cmux_tools.CmuxToolsClient().jira_assigned()
            self.assertEqual(error.exception.code, "cmux_invalid_response")
            self.assertEqual(error.exception.status, 502)
            self.assertEqual(error.exception.upstream_status, 200)

    def test_http_errors_preserve_safe_4xx_and_collapse_5xx(self):
        cases = ((404, 404), (503, 502))
        for upstream, expected_status in cases:
            body = io.BytesIO(json.dumps({"ok": False, "error": "workspace not found"}).encode())
            error_response = urllib.error.HTTPError(
                "http://cmux.example/api/git-status-path",
                upstream,
                "upstream failure",
                {"Content-Type": "application/json"},
                body,
            )
            with self.subTest(upstream=upstream), patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                side_effect=error_response,
            ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                cmux_tools.CmuxToolsClient().jira_assigned()
            self.assertEqual(
                str(error.exception),
                "workspace not found" if upstream == 404 else "cmux could not complete the request",
            )
            self.assertEqual(
                error.exception.code,
                "cmux_upstream_error",
            )
            self.assertEqual(error.exception.status, expected_status)
            self.assertEqual(error.exception.upstream_status, upstream)

    def test_http_200_ok_false_is_a_typed_upstream_error(self):
        response = _json_response({"ok": False, "error": "git failed\x00"})
        with patch(
            "herdr_harness.cmux_tools._open_no_redirect",
            return_value=response,
        ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
            cmux_tools.CmuxToolsClient().jira_assigned()

        self.assertEqual(str(error.exception), "git failed")
        self.assertEqual(error.exception.code, "cmux_upstream_error")
        self.assertEqual(error.exception.status, 502)
        self.assertEqual(error.exception.upstream_status, 200)

    def test_unreachable_and_timeout_errors_do_not_leak_transport_details(self):
        failures = (
            urllib.error.URLError("connection refused at secret-host"),
            TimeoutError("secret timeout details"),
        )
        for failure in failures:
            with self.subTest(failure=failure), patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                side_effect=failure,
            ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                cmux_tools.CmuxToolsClient().jira_assigned()
            self.assertEqual(
                str(error.exception),
                "The cmux tools service is unavailable.",
            )
            self.assertEqual(error.exception.code, "cmux_unavailable")
            self.assertEqual(error.exception.status, 503)
            self.assertIsNone(error.exception.upstream_status)


class CmuxToolsAttachmentTests(unittest.TestCase):
    def test_workspace_identity_prefers_exact_and_deduplicates_surfaces(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "checkout"
            nested = root / "Sources" / "Feature"
            nested.mkdir(parents=True)
            response = _json_response(
                {
                    # The live cmux status contract intentionally has no `ok`.
                    "workspaces": [
                        {"uuid": "nested-other", "index": 4, "cwd": str(nested)},
                        {"uuid": "cmux-live", "index": 700001, "cwd": str(root)},
                        {"uuid": "cmux-live", "index": 7, "cwd": str(root)},
                    ]
                }
            )
            with patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                return_value=response,
            ) as opened:
                identity = cmux_tools.CmuxToolsClient().attachment_workspace_identity(root)

        self.assertEqual(identity, {"uuid": "cmux-live", "index": 7})
        request = opened.call_args.args[0]
        self.assertEqual(request.method, "GET")
        self.assertEqual(urllib.parse.urlsplit(request.full_url).path, "/api/status")
        self.assertNotIn("authorization", _headers(request))

    def test_workspace_identity_accepts_descendant_cwd_and_deduplicates_uuid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "checkout"
            nested_one = root / "Sources"
            nested_two = root / "Tests"
            nested_one.mkdir(parents=True)
            nested_two.mkdir()
            response = _json_response(
                {
                    "workspaces": [
                        {"uuid": "cmux-live", "index": 900002, "cwd": str(nested_two)},
                        {"uuid": "cmux-live", "index": 9, "cwd": str(nested_one)},
                    ]
                }
            )
            with patch(
                "herdr_harness.cmux_tools._open_no_redirect",
                return_value=response,
            ):
                identity = cmux_tools.CmuxToolsClient().attachment_workspace_identity(root)

        self.assertEqual(identity, {"uuid": "cmux-live", "index": 9})

    def test_workspace_identity_rejects_zero_and_ambiguous_matches(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "checkout"
            child = root / "Sources"
            parent = Path(temp_dir)
            child.mkdir(parents=True)
            client = cmux_tools.CmuxToolsClient()
            cases = (
                (
                    {"workspaces": [{"uuid": "parent", "index": 1, "cwd": str(parent)}]},
                    "cmux_workspace_not_found",
                    404,
                ),
                (
                    {
                        "workspaces": [
                            {"uuid": "first", "index": 1, "cwd": str(root)},
                            {"uuid": "second", "index": 2, "cwd": str(root)},
                        ]
                    },
                    "cmux_workspace_ambiguous",
                    409,
                ),
            )
            for payload, expected_code, expected_status in cases:
                with self.subTest(code=expected_code), patch(
                    "herdr_harness.cmux_tools._open_no_redirect",
                    return_value=_json_response(payload),
                ), self.assertRaises(cmux_tools.CmuxToolsError) as error:
                    client.attachment_workspace_identity(root)
                self.assertEqual(error.exception.code, expected_code)
                self.assertEqual(error.exception.status, expected_status)

    def test_attachment_is_raw_and_uses_cmux_identity_headers_without_authorization(self):
        captured = []

        def open_request(request, timeout):
            captured.append((request, timeout))
            return _json_response(
                {
                    "ok": True,
                    "attachment": {
                        "id": "a1",
                        "filename": "stored-resume-notes.txt",
                        "originalFilename": "résumé notes.txt",
                        "contentType": "application/octet-stream",
                        "size": len(payload),
                        "path": "/tmp/a1",
                        "workspaceKey": "workspace-uuid",
                        "createdAt": "2026-08-12T12:00:00Z",
                    },
                }
            )

        payload = b"binary\x00attachment\xff"
        with patch(
            "herdr_harness.cmux_tools._open_no_redirect",
            side_effect=open_request,
        ):
            response = cmux_tools.CmuxToolsClient(timeout=9).upload_attachment(
                workspace_uuid="workspace-uuid",
                workspace_index=23,
                filename="résumé notes.txt",
                content_type="application/octet-stream",
                data=payload,
            )

        request, timeout = captured[0]
        parsed = urllib.parse.urlsplit(request.full_url)
        headers = _headers(request)
        self.assertEqual(request.method, "POST")
        self.assertEqual(parsed.path, "/api/attachments")
        self.assertEqual(parsed.query, "")
        self.assertEqual(request.data, payload)
        self.assertEqual(headers["content-type"], "application/octet-stream")
        self.assertEqual(
            headers["x-cmux-filename"],
            "r%C3%A9sum%C3%A9%20notes.txt",
        )
        self.assertEqual(headers["x-cmux-workspace-uuid"], "workspace-uuid")
        self.assertEqual(headers["x-cmux-workspace-index"], "23")
        self.assertNotIn("authorization", headers)
        self.assertEqual(timeout, 60.0)
        self.assertEqual(response["attachment"]["id"], "a1")

    def test_attachment_size_type_and_header_values_are_validated_before_network(self):
        client = cmux_tools.CmuxToolsClient()
        invalid_calls = (
            lambda: client.upload_attachment(
                filename="note.txt", content_type="text/plain", data=b""
            ),
            lambda: client.upload_attachment(filename="note.txt", content_type="text/plain", data="not-bytes"),
            lambda: client.upload_attachment(
                filename="", content_type="text/plain", data=b"1"
            ),
            lambda: client.upload_attachment(
                filename="note.txt", content_type="text/plain\r\nInjected: yes", data=b"1"
            ),
            lambda: client.upload_attachment(
                workspace_uuid="uuid\r\nInjected: yes",
                filename="note.txt",
                content_type="text/plain",
                data=b"1",
            ),
            lambda: client.upload_attachment(
                workspace_index="not-an-index",
                filename="note.txt",
                content_type="text/plain",
                data=b"1",
            ),
            lambda: client.upload_attachment(
                workspace_index=True,
                filename="note.txt",
                content_type="text/plain",
                data=b"1",
            ),
            lambda: client.upload_attachment(
                workspace_index=-1,
                filename="note.txt",
                content_type="text/plain",
                data=b"1",
            ),
        )

        with patch("herdr_harness.cmux_tools._open_no_redirect") as opened:
            for operation in invalid_calls:
                with self.subTest(operation=operation), self.assertRaises(cmux_tools.CmuxToolsError):
                    operation()
            with patch.object(cmux_tools, "MAX_ATTACHMENT_BYTES", 4):
                with self.assertRaises(cmux_tools.CmuxToolsError) as error:
                    client.upload_attachment(
                        filename="note.txt", content_type="text/plain", data=b"12345"
                    )
                self.assertEqual(error.exception.code, "attachment_too_large")
                self.assertEqual(error.exception.status, 413)
            opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
