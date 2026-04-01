import unittest

from cmux_harness.detection import detect_claude_session, fingerprint, is_permission_menu


class TestDetectClaudeSession(unittest.TestCase):

    def test_detects_idle_repl(self):
        screen = "Model: Opus 4  Cost: $0.45  Ctx: 12k"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_thinking(self):
        screen = "Musing..."
        self.assertTrue(detect_claude_session(screen))

    def test_detects_tool_use(self):
        screen = "⚡ Read file.py"
        self.assertTrue(detect_claude_session(screen))

    def test_detects_permission_prompt(self):
        screen = "Allow Read access to /path? (Y/n)"
        self.assertTrue(detect_claude_session(screen))

    def test_plain_shell_prompt(self):
        screen = "user@host ~ %"
        self.assertFalse(detect_claude_session(screen))

    def test_empty_screen(self):
        self.assertFalse(detect_claude_session(""))
        self.assertFalse(detect_claude_session(None))

    def test_detects_claude_command_in_history(self):
        screen = "$ claude\nStarting..."
        self.assertTrue(detect_claude_session(screen))


class TestIsPermissionMenu(unittest.TestCase):

    def test_yes_no_menu(self):
        options = "1. Yes\n2. No\n3. Type something else"
        self.assertTrue(is_permission_menu(options))

    def test_allow_menu(self):
        options = "1. Yes, allow reading from /src\n2. No\n3. Type something else"
        self.assertTrue(is_permission_menu(options))

    def test_domain_specific_menu(self):
        options = "1. src/main.py\n2. src/utils.py\n3. tests/test.py"
        self.assertFalse(is_permission_menu(options))

    def test_mixed_menu_with_file_choice(self):
        options = "1. Yes\n2. No\n3. Pick a different file"
        self.assertFalse(is_permission_menu(options))

    def test_all_permission_variants(self):
        options = (
            "1. Yes, and don't ask again for: bash\n"
            "2. Yes, allow from this project\n"
            "3. No\n"
            "4. Type something else"
        )
        self.assertTrue(is_permission_menu(options))

    def test_empty_options(self):
        self.assertFalse(is_permission_menu(""))


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
        # Verify it's a valid hex string
        int(result, 16)


if __name__ == "__main__":
    unittest.main()
