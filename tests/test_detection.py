import unittest

from cmux_harness.detection import detect_claude_session, fingerprint, is_permission_prompt


class TestDetectClaudeSession(unittest.TestCase):

    def test_detects_idle_repl(self):
        screen = "Model: Opus 4  Cost: $0.45  Ctx: 12k"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_thinking(self):
        screen = "Musing..."
        self.assertTrue(detect_claude_session(screen))

    def test_detects_tool_use(self):
        screen = "\u26a1 Read file.py"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_permission_prompt(self):
        screen = "Allow Read access to /path? (Y/n)"
        self.assertTrue(detect_claude_session(screen))

    def test_plain_shell_prompt(self):
        screen = "user@host ~ %"
        self.assertFalse(detect_claude_session(screen))

    def test_shell_prompt_after_exit_with_scrollback(self):
        screen = (
            "> /model\n"
            "  Set model to Sonnet 4.6 (default)\n"
            "\n"
            "> /exit\n"
            "Resume this session with:\n"
            "claude --resume abc123   Exit the REPL\n"
            "ronnierocha@ronniesitym4mbp cmux-harness %"
        )
        self.assertFalse(detect_claude_session(screen))

    def test_empty_screen(self):
        self.assertFalse(detect_claude_session(""))
        self.assertFalse(detect_claude_session(None))

    def test_detects_claude_command_in_history(self):
        screen = "$ claude\nStarting..."
        self.assertTrue(detect_claude_session(screen))


class TestIsPermissionPrompt(unittest.TestCase):

    def test_do_you_want_to_proceed(self):
        screen = "Bash command\n  git push origin main\nDo you want to proceed?\n> 1. Yes\n  2. No"
        self.assertTrue(is_permission_prompt(screen))

    def test_permission_rule_requires_confirmation(self):
        screen = "Permission rule Bash(git push *) requires confirmation for this command.\nDo you want to proceed?"
        self.assertTrue(is_permission_prompt(screen))

    def test_allow_read_yn(self):
        screen = "Allow Read access to /path/to/file? (Y/n)"
        self.assertTrue(is_permission_prompt(screen))

    def test_allow_bash(self):
        screen = "Allow Bash to run: npm test\n(Y/n)"
        self.assertTrue(is_permission_prompt(screen))

    def test_cursor_on_yes(self):
        screen = "\u276f 1. Yes\n  2. No\nEsc to cancel"
        self.assertTrue(is_permission_prompt(screen))

    def test_paren_cursor_on_yes(self):
        screen = ") 1. Yes\n  2. No\nEsc to cancel"
        self.assertTrue(is_permission_prompt(screen))

    def test_plain_shell_prompt_is_not_permission(self):
        screen = "user@host ~ %"
        self.assertFalse(is_permission_prompt(screen))

    def test_claude_working_is_not_permission(self):
        screen = "Musing...\n\u26a1 Read src/main.py"
        self.assertFalse(is_permission_prompt(screen))

    def test_empty_screen(self):
        self.assertFalse(is_permission_prompt(""))
        self.assertFalse(is_permission_prompt(None))


class TestFingerprint(unittest.TestCase):

    def test_same_input_same_hash(self):
        text = "line1\nline2\nline3"
        self.assertEqual(fingerprint(text), fingerprint(text))

    def test_different_input_different_hash(self):
        text_a = "header\nline1\nline2\nline3\nline4\nfoo"
        text_b = "header\nline1\nline2\nline3\nline4\nbar"
        self.assertNotEqual(fingerprint(text_a), fingerprint(text_b))

    def test_only_last_5_lines_matter(self):
        tail = "line1\nline2\nline3\nline4\nline5"
        text_a = "completely different header\n" + tail
        text_b = "another header entirely\n" + tail
        self.assertEqual(fingerprint(text_a), fingerprint(text_b))

    def test_short_screen(self):
        text = "line1\nline2"
        result = fingerprint(text)
        self.assertIsInstance(result, str)
        self.assertEqual(len(result), 32)
        int(result, 16)


if __name__ == "__main__":
    unittest.main()
