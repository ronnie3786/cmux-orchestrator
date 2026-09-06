import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from herdr_harness.session_labels import SessionLabelManager, parse_session_label, session_prompt_context


def snapshot(session="one", prompt="Fix unread notifications"):
    return {"session": {"id": session}, "entries": [
        {"message": {"role": "user", "content": [{"type": "text", "text": prompt}, {"type": "image", "data": "PRIVATE_IMAGE"}]}},
        {"message": {"role": "toolResult", "content": "PRIVATE_TOOL_RESULT"}},
    ]}


class SessionLabelTests(unittest.TestCase):
    def test_generates_persists_and_reuses_session_title_and_emoji(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "labels.json"
            generate = Mock(return_value='{"title":"Unread notifications", "emoji":"🔔"}')
            changed = Mock()
            manager = SessionLabelManager(generate, namespace="work", store_path=path, callback=changed)
            manager.observe("p1", snapshot())
            manager.process_pending()
            self.assertEqual(manager.label_for("p1"), {"session_title": "Unread notifications", "session_emoji": "🔔"})
            changed.assert_called_once_with("p1")
            self.assertNotIn("PRIVATE", str(generate.call_args))
            self.assertNotIn("Fix unread", path.read_text())
            restored = SessionLabelManager(generate, namespace="work", store_path=path)
            restored.observe("p1", snapshot())
            restored.process_pending()
            self.assertEqual(generate.call_count, 1)
            self.assertEqual(restored.label_for("p1"), manager.label_for("p1"))

    def test_reused_pane_clears_old_session_label_and_updates_after_debounce(self):
        now = [100.0]
        generate = Mock(side_effect=['{"title":"Unread notifications", "emoji":"🔔"}', '{"title":"New session", "emoji":"💬"}'])
        manager = SessionLabelManager(generate, clock=lambda: now[0])
        manager.observe("p1", snapshot())
        manager.process_pending()
        manager.observe("p1", snapshot(session="two", prompt="New work"))
        self.assertEqual(manager.label_for("p1"), {})
        now[0] += 60
        manager.process_pending()
        self.assertEqual(manager.label_for("p1")["session_title"], "New session")

    def test_stale_model_result_does_not_label_another_session(self):
        manager = None
        def generate(*args, **kwargs):
            manager.observe("p1", snapshot(session="two"))
            return '{"title":"Wrong session", "emoji":"🔔"}'
        manager = SessionLabelManager(generate)
        manager.observe("p1", snapshot())
        manager.process_pending()
        self.assertEqual(manager.label_for("p1"), {})

    def test_invalid_result_preserves_fallback_and_retries_later(self):
        now = [100.0]
        generate = Mock(side_effect=['bad json', '{"title":"Recovered title", "emoji":"🔔"}'])
        manager = SessionLabelManager(generate, clock=lambda: now[0])
        manager.observe("p1", snapshot())
        manager.process_pending()
        self.assertEqual(manager.label_for("p1"), {})
        manager.process_pending()
        self.assertEqual(generate.call_count, 1)
        now[0] += 60
        manager.process_pending()
        self.assertEqual(manager.label_for("p1")["session_title"], "Recovered title")

    def test_rejects_overlong_title_or_prose_emoji(self):
        for title, emoji in [("a" * 57, "🔔"), ("A title", "notification"), ("", "💬"), ("A title", "💬🔔")]:
            with self.assertRaises(ValueError):
                parse_session_label(json.dumps({"title": title, "emoji": emoji}))

    def test_live_user_message_labels_running_session_before_checkpoint(self):
        generate = Mock(return_value='{"title":"Fix notifications", "emoji":"🔔"}')
        manager = SessionLabelManager(generate)
        empty = {"session": {"sessionId": "one"}, "entries": []}
        manager.observe("p1", empty, live_prompt="Fix notifications while running")
        manager.observe("p1", empty)
        manager.process_pending()
        self.assertIn("Fix notifications while running", generate.call_args.args[0])
        self.assertEqual(manager.label_for("p1")["session_title"], "Fix notifications")

    def test_callback_failure_does_not_lose_label_or_stop_next_pane(self):
        generate = Mock(return_value='{"title":"Fix notifications", "emoji":"🔔"}')
        manager = SessionLabelManager(generate, callback=Mock(side_effect=RuntimeError("broker stopped")))
        manager.observe("p1", snapshot())
        manager.observe("p2", snapshot("two"))
        manager.process_pending()
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(manager.label_for("p1"), manager.label_for("p2"))

    def test_newer_prompt_rejects_inflight_stale_title(self):
        manager = None
        def generate(*args, **kwargs):
            manager.observe("p1", snapshot(prompt="A new topic"))
            return '{"title":"Old topic", "emoji":"💬"}'
        manager = SessionLabelManager(generate)
        manager.observe("p1", snapshot())
        manager.process_pending()
        self.assertEqual(manager.label_for("p1"), {})
