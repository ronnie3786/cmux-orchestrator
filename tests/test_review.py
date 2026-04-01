import unittest

from cmux_harness.review import parse_review_json, build_review_prompt


class TestParseReviewJson(unittest.TestCase):

    def test_clean_json(self):
        raw = '{"summary": "Did stuff", "confidence": "high"}'
        result = parse_review_json(raw)
        self.assertEqual(result, {"summary": "Did stuff", "confidence": "high"})

    def test_json_in_markdown_fence(self):
        raw = '```json\n{"summary": "test"}\n```'
        result = parse_review_json(raw)
        self.assertEqual(result, {"summary": "test"})

    def test_json_with_leading_text(self):
        raw = 'Here is my review:\n{"summary": "test"}'
        result = parse_review_json(raw)
        self.assertEqual(result, {"summary": "test"})

    def test_empty_input(self):
        self.assertIsNone(parse_review_json(""))
        self.assertIsNone(parse_review_json(None))

    def test_no_json(self):
        self.assertIsNone(parse_review_json("just plain text"))

    def test_invalid_json(self):
        self.assertIsNone(parse_review_json("{not valid json}"))

    def test_non_dict_json(self):
        self.assertIsNone(parse_review_json("[1, 2, 3]"))


class TestBuildReviewPrompt(unittest.TestCase):

    def _base_data(self, **overrides):
        data = {
            "workspaceName": "test-workspace",
            "branch": "main",
            "cwd": "/tmp",
            "duration": 60,
            "finalCost": "$0.01",
            "terminalSnapshot": "",
            "approvalLog": [],
            "gitDiff": "",
            "gitDiffStat": "",
            "gitLog": "",
        }
        data.update(overrides)
        return data

    def test_includes_workspace_name(self):
        data = self._base_data(workspaceName="my-project")
        prompt = build_review_prompt(data)
        self.assertIn("my-project", prompt)

    def test_includes_diff_when_present(self):
        data = self._base_data(
            gitDiff="diff --git a/foo.py b/foo.py\n+added line",
            gitDiffStat="foo.py | 1 +",
        )
        prompt = build_review_prompt(data)
        self.assertIn("Git diff summary", prompt)
        self.assertIn("Full diff", prompt)

    def test_no_diff_section_when_empty(self):
        data = self._base_data(gitDiff="", gitDiffStat="")
        prompt = build_review_prompt(data)
        self.assertIn("No uncommitted code changes detected", prompt)

    def test_counts_approvals_and_flags(self):
        data = self._base_data(
            approvalLog=[
                {"action": "approved bash command"},
                {"action": "approved file read"},
                {"action": "needs human review"},
                {"action": "flagged for human"},
                {"action": "approved write"},
            ]
        )
        prompt = build_review_prompt(data)
        self.assertIn("Actions auto-approved: 3", prompt)
        self.assertIn("Actions flagged for human: 2", prompt)


if __name__ == "__main__":
    unittest.main()
