import json
import os
import tempfile
import unittest
from unittest.mock import Mock, patch

from cmux_harness.cmux_api import (
    _find_socket_path,
    _parse_tree_data,
    _parse_notifications,
    _parse_debug_terminals,
    _parse_feed_items,
    _socket_candidate_paths,
    cmux_feed_reply,
    cmux_mark_notifications_read,
    cmux_send_to_workspace,
    _v2_request,
)


class TestSocketDiscovery(unittest.TestCase):

    def test_candidates_prefer_last_socket_path_before_stale_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            default_path = os.path.join(temp_dir, "cmux.sock")
            tagged_path = os.path.join(temp_dir, "cmux-501.sock")
            last_path_file = os.path.join(temp_dir, "last-socket-path")
            open(default_path, "w", encoding="utf-8").close()
            open(tagged_path, "w", encoding="utf-8").close()
            with open(last_path_file, "w", encoding="utf-8") as file:
                file.write(tagged_path)

            with patch.dict(os.environ, {"CMUX_SOCKET_PATH": ""}, clear=False), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_DIR", os.path.join(temp_dir, "state-missing")), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_SOCKET_PATH", os.path.join(temp_dir, "state-missing", "cmux.sock")), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_LAST_SOCKET_PATH_FILE", os.path.join(temp_dir, "state-missing", "last-socket-path")), \
                    patch("cmux_harness.cmux_api.CMUX_APP_SUPPORT_DIR", temp_dir), \
                    patch("cmux_harness.cmux_api.CMUX_DEFAULT_SOCKET_PATH", default_path), \
                    patch("cmux_harness.cmux_api.CMUX_LAST_SOCKET_PATH_FILE", last_path_file):
                candidates = _socket_candidate_paths()

            self.assertGreaterEqual(len(candidates), 2)
            self.assertEqual(candidates[0], tagged_path)
            self.assertIn(default_path, candidates)

    def test_find_socket_falls_back_when_env_socket_is_stale(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            stale_path = os.path.join(temp_dir, "cmux.sock")
            live_path = os.path.join(temp_dir, "cmux-501.sock")
            last_path_file = os.path.join(temp_dir, "last-socket-path")
            open(stale_path, "w", encoding="utf-8").close()
            open(live_path, "w", encoding="utf-8").close()
            with open(last_path_file, "w", encoding="utf-8") as file:
                file.write(live_path)

            def responds_to_ping(path):
                return path == live_path

            with patch.dict(os.environ, {"CMUX_SOCKET_PATH": stale_path}, clear=False), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_DIR", os.path.join(temp_dir, "state-missing")), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_SOCKET_PATH", os.path.join(temp_dir, "state-missing", "cmux.sock")), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_LAST_SOCKET_PATH_FILE", os.path.join(temp_dir, "state-missing", "last-socket-path")), \
                    patch("cmux_harness.cmux_api.CMUX_APP_SUPPORT_DIR", temp_dir), \
                    patch("cmux_harness.cmux_api.CMUX_DEFAULT_SOCKET_PATH", stale_path), \
                    patch("cmux_harness.cmux_api.CMUX_LAST_SOCKET_PATH_FILE", last_path_file), \
                    patch("cmux_harness.cmux_api._LAST_WORKING_SOCKET_PATH", None), \
                    patch("cmux_harness.cmux_api._socket_responds_to_ping", side_effect=responds_to_ping):
                self.assertEqual(_find_socket_path(), live_path)

    def test_candidates_include_state_socket_before_legacy_app_support(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = os.path.join(temp_dir, "state")
            app_dir = os.path.join(temp_dir, "app-support")
            os.mkdir(state_dir)
            os.mkdir(app_dir)
            state_path = os.path.join(state_dir, "cmux.sock")
            legacy_path = os.path.join(app_dir, "cmux.sock")
            open(state_path, "w", encoding="utf-8").close()
            open(legacy_path, "w", encoding="utf-8").close()

            with patch.dict(os.environ, {"CMUX_SOCKET_PATH": ""}, clear=False), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_DIR", state_dir), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_SOCKET_PATH", state_path), \
                    patch("cmux_harness.cmux_api.CMUX_STATE_LAST_SOCKET_PATH_FILE", os.path.join(state_dir, "last-socket-path")), \
                    patch("cmux_harness.cmux_api.CMUX_APP_SUPPORT_DIR", app_dir), \
                    patch("cmux_harness.cmux_api.CMUX_DEFAULT_SOCKET_PATH", legacy_path), \
                    patch("cmux_harness.cmux_api.CMUX_LAST_SOCKET_PATH_FILE", os.path.join(app_dir, "last-socket-path")):
                candidates = _socket_candidate_paths()

            self.assertEqual(candidates[0], state_path)
            self.assertLess(candidates.index(state_path), candidates.index(legacy_path))


class TestParseTreeData(unittest.TestCase):

    def test_basic_single_workspace(self):
        data = {
            "windows": [{
                "workspaces": [{
                    "index": 0,
                    "panes": [{
                        "ref": "pane:1",
                        "surfaces": [{
                            "ref": "surface:1",
                            "id": "AAA-BBB",
                            "title": "my session",
                            "type": "terminal",
                            "selected_in_pane": True,
                        }],
                    }],
                }],
            }],
        }
        result = _parse_tree_data(data)
        self.assertEqual(len(result), 1)
        self.assertIn(0, result)
        surfaces = result[0]
        self.assertEqual(len(surfaces), 1)
        self.assertEqual(surfaces[0]["ref"], "surface:1")
        self.assertEqual(surfaces[0]["id"], "AAA-BBB")
        self.assertEqual(surfaces[0]["title"], "my session")
        self.assertEqual(surfaces[0]["pane_ref"], "pane:1")
        self.assertTrue(surfaces[0]["selected_in_pane"])

    def test_empty_windows(self):
        self.assertEqual(_parse_tree_data({"windows": []}), {})

    def test_none_input(self):
        self.assertEqual(_parse_tree_data(None), {})

    def test_non_dict_input(self):
        self.assertEqual(_parse_tree_data("not a dict"), {})

    def test_filters_non_terminal_surfaces(self):
        data = {
            "windows": [{
                "workspaces": [{
                    "index": 0,
                    "panes": [{
                        "ref": "pane:1",
                        "surfaces": [
                            {"ref": "surface:1", "type": "terminal", "title": "term", "selected_in_pane": True},
                            {"ref": "surface:2", "type": "browser", "title": "web", "selected_in_pane": False},
                        ],
                    }],
                }],
            }],
        }
        result = _parse_tree_data(data)
        self.assertEqual(len(result[0]), 1)
        self.assertEqual(result[0][0]["ref"], "surface:1")

    def test_multi_surface_workspace(self):
        data = {
            "windows": [{
                "workspaces": [{
                    "index": 3,
                    "panes": [{
                        "ref": "pane:1",
                        "surfaces": [
                            {"ref": "surface:10", "id": "UUID-A", "type": "terminal", "title": "a", "selected_in_pane": True},
                            {"ref": "surface:11", "id": "UUID-B", "type": "terminal", "title": "b", "selected_in_pane": False},
                        ],
                    }],
                }],
            }],
        }
        result = _parse_tree_data(data)
        self.assertEqual(len(result[3]), 2)
        self.assertEqual(result[3][0]["id"], "UUID-A")
        self.assertEqual(result[3][1]["id"], "UUID-B")

    def test_workspace_missing_index_skipped(self):
        data = {
            "windows": [{
                "workspaces": [
                    {"panes": [{"ref": "p", "surfaces": [{"ref": "s", "type": "terminal", "title": "t"}]}]},
                ],
            }],
        }
        result = _parse_tree_data(data)
        self.assertEqual(result, {})


class TestParseNotifications(unittest.TestCase):

    def test_unread_notifications(self):
        result = {
            "notifications": [
                {"workspace_id": "WS-1", "is_read": False, "title": "Claude Code"},
                {"workspace_id": "WS-2", "is_read": True, "title": "Claude Code"},
                {"workspace_id": "WS-3", "is_read": False, "title": "Claude Code"},
            ]
        }
        parsed = _parse_notifications(result)
        self.assertEqual(len(parsed), 3)
        unread = [n for n in parsed if not n.get("is_read", True)]
        self.assertEqual(len(unread), 2)
        self.assertEqual({n["workspace_id"] for n in unread}, {"WS-1", "WS-3"})

    def test_all_read(self):
        result = {
            "notifications": [
                {"workspace_id": "WS-1", "is_read": True},
            ]
        }
        parsed = _parse_notifications(result)
        unread = [n for n in parsed if not n.get("is_read", True)]
        self.assertEqual(len(unread), 0)

    def test_empty_notifications(self):
        self.assertEqual(_parse_notifications({"notifications": []}), [])

    def test_none_input(self):
        self.assertEqual(_parse_notifications(None), [])

    def test_list_format(self):
        """Some cmux versions return a bare list instead of {notifications: [...]}."""
        result = [
            {"workspace_id": "WS-1", "is_read": False},
        ]
        parsed = _parse_notifications(result)
        self.assertEqual(len(parsed), 1)


class TestMarkNotificationsRead(unittest.TestCase):

    @patch("cmux_harness.cmux_api._v2_request")
    @patch("cmux_harness.cmux_api.ensure_workspace_terminal_ready", return_value=True)
    def test_mark_read_succeeds_via_notification_method(self, mock_focus, mock_v2):
        mock_v2.return_value = {"ok": True}
        result = cmux_mark_notifications_read(
            workspace_id="ws-1",
            surface_id="surf-1",
        )
        self.assertTrue(result)
        mock_v2.assert_called_once_with(
            "notification.mark_read",
            {"workspace_id": "ws-1", "surface_id": "surf-1"},
        )

    @patch("cmux_harness.cmux_api._v2_request", return_value=None)
    @patch("cmux_harness.cmux_api.ensure_workspace_terminal_ready", return_value=True)
    def test_mark_read_falls_back_to_surface_focus(self, mock_focus, mock_v2):
        result = cmux_mark_notifications_read(
            workspace_id="ws-1",
            surface_id="surf-1",
        )
        self.assertTrue(result)
        mock_focus.assert_called_once_with(
            workspace_uuid="ws-1",
            surface_id="surf-1",
        )

    @patch("cmux_harness.cmux_api._v2_request", return_value=None)
    @patch("cmux_harness.cmux_api.ensure_workspace_terminal_ready", return_value=False)
    def test_mark_read_returns_false_when_both_approaches_fail(self, mock_focus, mock_v2):
        result = cmux_mark_notifications_read(
            workspace_id="ws-1",
            surface_id="surf-1",
        )
        self.assertFalse(result)

    @patch("cmux_harness.cmux_api._v2_request", return_value=None)
    @patch("cmux_harness.cmux_api.ensure_workspace_terminal_ready", return_value=False)
    def test_mark_read_with_only_workspace_id(self, mock_focus, mock_v2):
        result = cmux_mark_notifications_read(workspace_id="ws-1")
        self.assertFalse(result)
        mock_v2.assert_called_once_with(
            "notification.mark_read",
            {"workspace_id": "ws-1"},
        )

    @patch("cmux_harness.cmux_api._v2_request", return_value=None)
    @patch("cmux_harness.cmux_api.ensure_workspace_terminal_ready", return_value=False)
    def test_mark_read_with_only_surface_id(self, mock_focus, mock_v2):
        result = cmux_mark_notifications_read(surface_id="surf-1")
        self.assertFalse(result)
        mock_v2.assert_called_once_with(
            "notification.mark_read",
            {"surface_id": "surf-1"},
        )


class TestParseDebugTerminals(unittest.TestCase):

    def test_basic_parsing(self):
        result = {
            "terminals": [
                {
                    "surface_id": "UUID-SURF-1",
                    "surface_title": "Fix auth bug",
                    "git_dirty": True,
                    "surface_created_at": "2026-04-01T10:00:00Z",
                    "runtime_surface_age_seconds": 3600.5,
                    "current_directory": "/Users/dev/project",
                    "workspace_ref": "workspace:1",
                },
            ]
        }
        parsed = _parse_debug_terminals(result)
        self.assertIn("UUID-SURF-1", parsed)
        entry = parsed["UUID-SURF-1"]
        self.assertEqual(entry["surface_title"], "Fix auth bug")
        self.assertTrue(entry["git_dirty"])
        self.assertEqual(entry["surface_created_at"], "2026-04-01T10:00:00Z")
        self.assertAlmostEqual(entry["runtime_surface_age_seconds"], 3600.5)
        self.assertEqual(entry["current_directory"], "/Users/dev/project")
        self.assertEqual(entry["workspace_ref"], "workspace:1")

    def test_missing_fields_get_defaults(self):
        result = {
            "terminals": [
                {"surface_id": "UUID-1"},
            ]
        }
        parsed = _parse_debug_terminals(result)
        entry = parsed["UUID-1"]
        self.assertEqual(entry["surface_title"], "")
        self.assertFalse(entry["git_dirty"])
        self.assertEqual(entry["surface_created_at"], "")
        self.assertEqual(entry["runtime_surface_age_seconds"], 0)

    def test_empty_terminals(self):
        self.assertEqual(_parse_debug_terminals({"terminals": []}), {})

    def test_none_input(self):
        self.assertEqual(_parse_debug_terminals(None), {})

    def test_skips_entries_without_surface_id(self):
        result = {
            "terminals": [
                {"surface_title": "no id"},
                {"surface_id": "UUID-1", "surface_title": "has id"},
            ]
        }
        parsed = _parse_debug_terminals(result)
        self.assertEqual(len(parsed), 1)
        self.assertIn("UUID-1", parsed)

    def test_list_format(self):
        """Some responses may return a bare list."""
        result = [{"surface_id": "UUID-1", "surface_title": "test"}]
        parsed = _parse_debug_terminals(result)
        self.assertEqual(len(parsed), 1)
        self.assertIn("UUID-1", parsed)


class TestParseFeedItems(unittest.TestCase):

    def test_normalizes_permission_request(self):
        parsed = _parse_feed_items({
            "items": [{
                "request_id": "req-1",
                "type": "permission",
                "status": "pending",
                "title": "Bash command",
                "message": "Run tests?",
                "command": "pytest",
                "workspace_id": "ws-1",
                "surface_id": "surf-1",
            }],
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["requestID"], "req-1")
        self.assertEqual(item["kind"], "permission")
        self.assertEqual(item["title"], "Bash command")
        self.assertEqual(item["message"], "Run tests?")
        self.assertEqual(item["command"], "pytest")
        self.assertEqual(item["workspaceID"], "ws-1")
        self.assertEqual(item["surfaceID"], "surf-1")
        self.assertEqual(item["raw"]["request_id"], "req-1")

    def test_normalizes_actual_feed_list_permission_shape(self):
        tool_input = {
            "permission": "external_directory",
            "patterns": ["/private/tmp/*", "/repo/generated/*"],
            "metadata": {"tool": "read"},
        }
        parsed = _parse_feed_items({
            "items": [{
                "id": "item-1",
                "workstream_id": "opencode-session-1",
                "source": "opencode",
                "kind": "permissionRequest",
                "created_at": "2026-07-19T21:00:00Z",
                "updated_at": "2026-07-19T21:00:01Z",
                "cwd": "/repo",
                "status": "pending",
                "request_id": "permission-1",
                "tool_name": "external_directory",
                "tool_input": json.dumps(tool_input),
                "pattern": "/repo/generated/*",
            }],
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["workstreamID"], "opencode-session-1")
        self.assertEqual(item["cwd"], "/repo")
        self.assertEqual(item["agent"], "opencode")
        self.assertEqual(item["permissionType"], "external_directory")
        self.assertEqual(item["patterns"], ["/repo/generated/*", "/private/tmp/*"])
        self.assertEqual(item["toolInput"], tool_input)
        self.assertEqual(item["command"], "")
        self.assertEqual(
            [entry["mode"] for entry in item["permissionModes"]],
            ["once", "always", "all", "bypass", "deny"],
        )

    def test_permission_modes_follow_source_and_codex_capabilities(self):
        missing = object()
        cases = [
            ("opencode", missing, ["once", "always", "all", "bypass", "deny"]),
            ("claude", missing, ["once", "always", "all", "deny"]),
            ("hermes-agent", missing, ["once", "deny"]),
            ("codex", missing, ["once", "always", "all", "deny"]),
            ("codex", "{}", ["once", "always", "deny"]),
            ("codex", "not-json", ["deny"]),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": ["accept"],
                }),
                ["once", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": ["acceptForSession"],
                }),
                ["always", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": ["acceptWithExecpolicyAmendment"],
                    "proposed_execpolicy_amendment": True,
                }),
                ["all", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": ["applyNetworkPolicyAmendment"],
                    "proposed_network_policy_amendments": [True],
                }),
                ["all", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/fileChange/requestApproval",
                    "available_decisions": ["accept", "acceptForSession"],
                    "proposed_execpolicy_amendment": True,
                }),
                ["once", "always", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/permissions/requestApproval",
                    "available_decisions": [],
                }),
                ["once", "always", "all", "deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": None,
                }),
                ["deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/fileChange/requestApproval",
                    "available_decisions": "accept",
                }),
                ["deny"],
            ),
            (
                "codex",
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": {},
                }),
                ["deny"],
            ),
        ]

        for index, (source, capabilities, expected_modes) in enumerate(cases):
            with self.subTest(source=source, capabilities=capabilities):
                item = {
                    "kind": "permissionRequest",
                    "status": "pending",
                    "request_id": f"permission-matrix-{index}",
                    "source": source,
                }
                if capabilities is not missing:
                    item["tool_input_capabilities"] = capabilities

                parsed = _parse_feed_items({"items": [item]})

                self.assertEqual(
                    [entry["mode"] for entry in parsed[0]["permissionModes"]],
                    expected_modes,
                )

    def test_codex_capabilities_fall_back_to_raw_tool_input(self):
        cases = [
            ("not-json", ["deny"]),
            (
                json.dumps({
                    "app_server_method": "item/commandExecution/requestApproval",
                    "available_decisions": ["acceptWithExecpolicyAmendment"],
                    "proposed_execpolicy_amendment": {"command": "git status"},
                }),
                ["all", "deny"],
            ),
        ]

        for index, (tool_input, expected_modes) in enumerate(cases):
            with self.subTest(tool_input=tool_input):
                parsed = _parse_feed_items({"items": [{
                    "kind": "permissionRequest",
                    "status": "pending",
                    "request_id": f"permission-raw-capabilities-{index}",
                    "source": "codex",
                    "tool_input": tool_input,
                }]})

                self.assertEqual(
                    [entry["mode"] for entry in parsed[0]["permissionModes"]],
                    expected_modes,
                )

    def test_infers_plan_and_question_items(self):
        parsed = _parse_feed_items([
            {"request_id": "plan-1", "kind": "exit-plan", "status": "pending", "prompt": "Approve plan?"},
            {"request_id": "q-1", "requestType": "question", "status": "pending", "question": "Pick one", "options": ["A", "B"]},
        ])

        self.assertEqual([item["kind"] for item in parsed], ["plan", "question"])
        self.assertEqual(parsed[1]["options"], ["A", "B"])

    def test_normalizes_opencode_permission_hook(self):
        parsed = _parse_feed_items([{
            "hook_event_name": "PermissionRequest",
            "_opencode_request_id": "permission-1",
            "_source": "opencode",
            "workspace_id": "ws-1",
            "tool_name": "external_directory",
            "tool_input": {
                "permission": "external_directory",
                "patterns": ["/tmp/*", "/private/tmp/*"],
            },
        }])

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["requestID"], "permission-1")
        self.assertEqual(item["kind"], "permission")
        self.assertEqual(item["permissionType"], "external_directory")
        self.assertEqual(item["patterns"], ["/tmp/*", "/private/tmp/*"])
        self.assertEqual(item["command"], "")
        self.assertEqual(item["options"], [])
        self.assertEqual(item["agent"], "opencode")

    def test_normalizes_wrapped_opencode_questions(self):
        parsed = _parse_feed_items({
            "workspace_id": "ws-1",
            "surface_id": "surf-1",
            "event": {
                "hook_event_name": "AskUserQuestion",
                "_opencode_request_id": "question-1",
                "tool_input": {
                    "questions": [{
                        "id": "environment",
                        "header": "Environment",
                        "question": "Where should this run?",
                        "multiSelect": True,
                        "options": [
                            {"id": "staging", "label": "Staging", "description": "Shared QA"},
                            {"id": "prod", "title": "Production", "detail": "Live traffic"},
                        ],
                    }],
                },
            },
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["requestID"], "question-1")
        self.assertEqual(item["kind"], "question")
        self.assertEqual(item["workspaceID"], "ws-1")
        self.assertEqual(item["surfaceID"], "surf-1")
        self.assertEqual(item["message"], "Where should this run?")
        self.assertEqual(item["options"], ["Staging", "Production"])
        self.assertEqual(item["questions"], [{
            "id": "environment",
            "header": "Environment",
            "question": "Where should this run?",
            "multiSelect": True,
            "options": [
                {"id": "staging", "label": "Staging", "description": "Shared QA"},
                {"id": "prod", "label": "Production", "description": "Live traffic"},
            ],
        }])

    def test_normalizes_opencode_exit_plan_hook_and_dict_options(self):
        parsed = _parse_feed_items([{
            "hook_event_name": "ExitPlanMode",
            "_opencode_request_id": "plan-1",
            "tool_input": {"question": "Ready to build?"},
            "options": [
                {"label": "Build"},
                {"title": "Keep planning"},
                3,
            ],
        }])

        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["requestID"], "plan-1")
        self.assertEqual(parsed[0]["kind"], "plan")
        self.assertEqual(parsed[0]["message"], "Ready to build?")
        self.assertEqual(parsed[0]["options"], ["Build", "Keep planning", "3"])

    def test_normalizes_actual_feed_list_questions_shape(self):
        parsed = _parse_feed_items({
            "items": [{
                "id": "item-question-1",
                "workstream_id": "opencode-session-1",
                "source": "opencode",
                "kind": "question",
                "cwd": "/repo",
                "status": "pending",
                "request_id": "question-1",
                "questions": [{
                    "id": "environment",
                    "header": "Environment",
                    "prompt": "Where should this run?",
                    "multi_select": True,
                    "custom": False,
                    "options": [
                        {"id": "staging", "label": "Staging", "description": "Shared QA"},
                        {"id": "prod", "label": "Production", "description": "Live traffic"},
                    ],
                }, {
                    "id": "checks",
                    "prompt": "Which checks?",
                    "multiple": "true",
                    "options": ["Unit", "UI"],
                }],
            }],
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["message"], "Where should this run?")
        self.assertEqual(item["options"], ["Staging", "Production", "Unit", "UI"])
        self.assertEqual(item["questions"], [{
            "id": "environment",
            "header": "Environment",
            "question": "Where should this run?",
            "multiSelect": True,
            "options": [
                {"id": "staging", "label": "Staging", "description": "Shared QA"},
                {"id": "prod", "label": "Production", "description": "Live traffic"},
            ],
            "allowsCustomAnswer": False,
        }, {
            "id": "checks",
            "header": "",
            "question": "Which checks?",
            "multiSelect": True,
            "options": [
                {"id": "opt0", "label": "Unit", "description": ""},
                {"id": "opt1", "label": "UI", "description": ""},
            ],
        }])

    def test_synthesizes_question_from_feed_list_compatibility_fields(self):
        parsed = _parse_feed_items({
            "items": [{
                "id": "item-question-compat",
                "workstream_id": "claude-session-1",
                "source": "claude",
                "kind": "question",
                "status": "pending",
                "request_id": "question-compat",
                "question_prompt": "Choose a deploy target",
                "question_multi_select": False,
                "question_custom": True,
                "question_options": [
                    {"id": "staging", "label": "Staging", "description": "Shared QA"},
                    {"id": "prod", "label": "Production", "description": "Live traffic"},
                ],
            }],
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["message"], "Choose a deploy target")
        self.assertEqual(item["options"], ["Staging", "Production"])
        self.assertEqual(item["questions"], [{
            "id": "q0",
            "header": "",
            "question": "Choose a deploy target",
            "multiSelect": False,
            "options": [
                {"id": "staging", "label": "Staging", "description": "Shared QA"},
                {"id": "prod", "label": "Production", "description": "Live traffic"},
            ],
            "allowsCustomAnswer": True,
        }])

    def test_invalid_question_array_uses_feed_list_compatibility_fields(self):
        parsed = _parse_feed_items({
            "items": [{
                "kind": "question",
                "status": "pending",
                "request_id": "question-empty-compat",
                "questions": [{}],
                "question_prompt": "Choose a release channel",
                "question_options": ["Beta", "Stable"],
            }],
        })

        self.assertEqual(parsed[0]["questions"], [{
            "id": "q0",
            "header": "",
            "question": "Choose a release channel",
            "multiSelect": False,
            "options": [
                {"id": "opt0", "label": "Beta", "description": ""},
                {"id": "opt1", "label": "Stable", "description": ""},
            ],
        }])

    def test_structured_question_uses_header_or_default_prompt(self):
        parsed = _parse_feed_items({"items": [{
            "kind": "question",
            "status": "pending",
            "request_id": "question-prompt-fallbacks",
            "questions": [{
                "id": "header-only",
                "header": "Deployment target",
                "options": [],
            }, {
                "id": "options-only",
                "options": ["Beta", "Stable"],
            }],
        }]})

        self.assertEqual(
            [question["question"] for question in parsed[0]["questions"]],
            ["Deployment target", "Answer the agent question."],
        )
        self.assertEqual(
            [question["header"] for question in parsed[0]["questions"]],
            ["", ""],
        )

    def test_question_normalization_drops_blank_rows_and_stabilizes_duplicate_ids(self):
        parsed = _parse_feed_items({
            "items": [{
                "kind": "question",
                "status": "pending",
                "request_id": "question-duplicate-options",
                "questions": [{
                    "id": "question",
                    "prompt": "First?",
                    "options": [
                        {"id": "choice", "label": "Alpha"},
                        {"id": "choice", "label": "  "},
                        {"id": "choice", "label": "Beta"},
                    ],
                }, {
                    "id": "question",
                    "prompt": "Second?",
                    "options": ["Gamma"],
                }],
            }],
        })

        questions = parsed[0]["questions"]
        self.assertEqual([question["id"] for question in questions], ["question", "question-2"])
        self.assertEqual(
            [(option["id"], option["label"]) for option in questions[0]["options"]],
            [("choice", "Alpha"), ("choice-2", "Beta")],
        )

    def test_normalizes_actual_feed_list_exit_plan_shape(self):
        parsed = _parse_feed_items({
            "items": [{
                "id": "item-plan-1",
                "workstream_id": "claude-session-1",
                "source": "claude",
                "kind": "exitPlan",
                "cwd": "/repo",
                "status": "pending",
                "request_id": "plan-1",
                "plan": "# Implement permission UI\n\n1. Normalize the feed.",
                "plan_summary": "# Implement permission UI",
                "default_mode": "manual",
            }],
        })

        self.assertEqual(len(parsed), 1)
        item = parsed[0]
        self.assertEqual(item["kind"], "plan")
        self.assertEqual(item["message"], "# Implement permission UI")
        self.assertEqual(item["plan"], "# Implement permission UI\n\n1. Normalize the feed.")
        self.assertEqual(item["planSummary"], "# Implement permission UI")
        self.assertEqual(item["defaultMode"], "manual")
        self.assertEqual(item["workstreamID"], "claude-session-1")
        self.assertEqual(item["cwd"], "/repo")

    def test_skips_telemetry_and_expired_feed_history(self):
        parsed = _parse_feed_items([
            {"id": "event-1", "kind": "sessionStart", "status": "telemetry"},
            {"id": "event-2", "kind": "toolUse", "status": "telemetry", "tool_input": "{}"},
            {
                "request_id": "expired-1",
                "kind": "permissionRequest",
                "status": "expired",
                "resolved_at": "2026-05-06T20:03:12Z",
            },
            {"request_id": "active-1", "kind": "permissionRequest", "status": "pending"},
        ])

        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["requestID"], "active-1")
        self.assertEqual(parsed[0]["kind"], "permission")

    def test_empty_or_invalid_feed(self):
        self.assertEqual(_parse_feed_items({"items": []}), [])
        self.assertEqual(_parse_feed_items(None), [])
        self.assertEqual(_parse_feed_items({"items": ["bad"]}), [])


class TestFeedReply(unittest.TestCase):

    def test_permission_reply_maps_approve_to_once(self):
        with patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True}) as mock_request:
            result = cmux_feed_reply("permission", "req-1", action="approve")

        self.assertTrue(result["ok"])
        mock_request.assert_called_once_with("feed.permission.reply", {
            "request_id": "req-1",
            "mode": "once",
        })

    def test_plan_reply_maps_approve_to_auto_accept(self):
        with patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True}) as mock_request:
            result = cmux_feed_reply("plan", "req-1", action="approve")

        self.assertTrue(result["ok"])
        mock_request.assert_called_once_with("feed.exit_plan.reply", {
            "request_id": "req-1",
            "mode": "autoAccept",
        })

    def test_question_reply_sends_selections(self):
        with patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True}) as mock_request:
            result = cmux_feed_reply("question", "req-1", selections=["A"])

        self.assertTrue(result["ok"])
        mock_request.assert_called_once_with("feed.question.reply", {
            "request_id": "req-1",
            "selections": ["A"],
        })

    def test_question_reply_sends_explicit_empty_selections(self):
        with patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True}) as mock_request:
            result = cmux_feed_reply("question", "req-1", selections=[])

        self.assertTrue(result["ok"])
        mock_request.assert_called_once_with("feed.question.reply", {
            "request_id": "req-1",
            "selections": [],
        })

    def test_question_reply_preserves_blank_answer_positions(self):
        with patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True}) as mock_request:
            result = cmux_feed_reply(
                "question",
                "req-1",
                selections=["Staging", "   ", "Unit, UI"],
            )

        self.assertTrue(result["ok"])
        mock_request.assert_called_once_with("feed.question.reply", {
            "request_id": "req-1",
            "selections": ["Staging", "", "Unit, UI"],
        })

    def test_unknown_or_invalid_replies_never_default_to_approval(self):
        with patch("cmux_harness.cmux_api._v2_request") as mock_request:
            unknown_permission = cmux_feed_reply("permission", "req-1", action="surprise")
            invalid_permission_mode = cmux_feed_reply("permission", "req-1", mode="approveEverything")
            unknown_plan = cmux_feed_reply("plan", "req-1", action="surprise")
            missing_question = cmux_feed_reply("question", "req-1", action="answer")
            non_list_question = cmux_feed_reply("question", "req-1", selections="A")

        self.assertFalse(unknown_permission["ok"])
        self.assertFalse(invalid_permission_mode["ok"])
        self.assertFalse(unknown_plan["ok"])
        self.assertFalse(missing_question["ok"])
        self.assertFalse(non_list_question["ok"])
        mock_request.assert_not_called()

    def test_missing_request_id_is_error(self):
        result = cmux_feed_reply("permission", "", action="approve")
        self.assertFalse(result["ok"])


class TestSendToWorkspace(unittest.TestCase):

    @patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True})
    def test_space_key_uses_literal_text_for_checkbox_toggles(self, mock_v2_request):
        result = cmux_send_to_workspace(
            0,
            0,
            key="space",
            workspace_uuid="workspace-1",
            surface_id="surface-1",
        )

        self.assertTrue(result)
        mock_v2_request.assert_called_once_with(
            "surface.send_text",
            {"workspace_id": "workspace-1", "text": " ", "surface_id": "surface-1"},
        )

    @patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True})
    def test_extended_terminal_keys_use_send_key(self, mock_v2_request):
        keys = ["left", "right", "escape", "backspace"]

        for key in keys:
            with self.subTest(key=key):
                mock_v2_request.reset_mock()

                result = cmux_send_to_workspace(
                    0,
                    0,
                    key=key,
                    workspace_uuid="workspace-1",
                    surface_id="surface-1",
                )

                self.assertTrue(result)
                mock_v2_request.assert_called_once_with(
                    "surface.send_key",
                    {"workspace_id": "workspace-1", "key": key, "surface_id": "surface-1"},
                )

    @patch("cmux_harness.cmux_api._v2_request", return_value={"ok": True})
    def test_primary_terminal_keys_still_use_send_key(self, mock_v2_request):
        result = cmux_send_to_workspace(
            0,
            0,
            key="enter",
            workspace_uuid="workspace-1",
            surface_id="surface-1",
        )

        self.assertTrue(result)
        mock_v2_request.assert_called_once_with(
            "surface.send_key",
            {"workspace_id": "workspace-1", "key": "enter", "surface_id": "surface-1"},
        )


class TestV2Request(unittest.TestCase):

    def test_surface_read_text_suppresses_not_terminal_warning(self):
        fake_socket = Mock()
        fake_socket.recv.side_effect = [json.dumps({
            "ok": False,
            "error": "Surface is not a terminal",
        }).encode() + b"\n", b""]

        with patch("cmux_harness.cmux_api._find_socket_path", return_value="/tmp/cmux.sock"), \
                patch("cmux_harness.cmux_api.socket.socket", return_value=fake_socket), \
                patch("cmux_harness.cmux_api.log.warning") as mock_warning:
            result = _v2_request("surface.read_text", {"workspace_id": "ws-1"})

        self.assertIsNone(result)
        mock_warning.assert_not_called()

    def test_other_v2_errors_still_log_warning(self):
        fake_socket = Mock()
        fake_socket.recv.side_effect = [json.dumps({
            "ok": False,
            "error": "permission denied",
        }).encode() + b"\n", b""]

        with patch("cmux_harness.cmux_api._find_socket_path", return_value="/tmp/cmux.sock"), \
                patch("cmux_harness.cmux_api.socket.socket", return_value=fake_socket), \
                patch("cmux_harness.cmux_api.log.warning") as mock_warning:
            result = _v2_request("workspace.list", {})

        self.assertIsNone(result)
        mock_warning.assert_called_once()
