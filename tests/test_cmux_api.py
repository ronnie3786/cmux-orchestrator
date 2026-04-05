import json
import unittest
from unittest.mock import Mock, patch

from cmux_harness.cmux_api import (
    _parse_tree_data,
    _parse_notifications,
    _parse_debug_terminals,
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
