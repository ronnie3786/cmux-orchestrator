import json
import unittest
from unittest.mock import Mock, patch

from cmux_harness.cmux_api import (
    _parse_tree_data,
    _parse_notifications,
    _parse_debug_terminals,
    _parse_feed_items,
    cmux_feed_reply,
    cmux_send_to_workspace,
    _v2_request,
)


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

    def test_infers_plan_and_question_items(self):
        parsed = _parse_feed_items([
            {"request_id": "plan-1", "kind": "exit-plan", "status": "pending", "prompt": "Approve plan?"},
            {"request_id": "q-1", "requestType": "question", "status": "pending", "question": "Pick one", "options": ["A", "B"]},
        ])

        self.assertEqual([item["kind"] for item in parsed], ["plan", "question"])
        self.assertEqual(parsed[1]["options"], ["A", "B"])

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

    def test_missing_request_id_is_error(self):
        result = cmux_feed_reply("permission", "", action="approve")
        self.assertFalse(result["ok"])


class TestSendToWorkspace(unittest.TestCase):

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
