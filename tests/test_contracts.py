import unittest

from cmux_harness import contracts


class TestContracts(unittest.TestCase):

    def test_build_contract_prompt_includes_task_fields(self):
        prompt = contracts.build_contract_prompt(
            {
                "title": "Ship login flow",
                "userStory": "Users can sign in without errors.",
                "deliverables": ["Working login screen", "Session persistence"],
                "checkpoints": ["Login succeeds", {"name": "Session survives relaunch"}],
            }
        )

        self.assertIn("Ship login flow", prompt)
        self.assertIn("Users can sign in without errors.", prompt)
        self.assertIn("Working login screen", prompt)
        self.assertIn("Session survives relaunch", prompt)
        self.assertIn("## Acceptance Criteria", prompt)
        self.assertIn("/exp-project-run", prompt)

    def test_parse_contract_returns_sections(self):
        parsed = contracts.parse_contract(
            """## Acceptance Criteria
1. Users can log in successfully.

## Build Verification
- /exp-project-run

## Functional Test Hints
- Maestro flow covers login and logout.

## Pass/Fail Threshold
- Fail if login or logout breaks.
"""
        )

        self.assertEqual(parsed["acceptanceCriteria"], "1. Users can log in successfully.")
        self.assertEqual(parsed["buildVerification"], "- /exp-project-run")
        self.assertEqual(parsed["functionalTestHints"], "- Maestro flow covers login and logout.")
        self.assertEqual(parsed["passFailThreshold"], "- Fail if login or logout breaks.")

    def test_parse_contract_returns_none_when_section_missing(self):
        self.assertIsNone(contracts.parse_contract("## Acceptance Criteria\n1. Only one section"))

    def test_build_contract_evaluator_prompt_mentions_contract_and_task(self):
        prompt = contracts.build_contract_evaluator_prompt(
            {
                "title": "Ship login flow",
                "userStory": "Users can sign in without errors.",
                "deliverables": ["Working login screen"],
                "checkpoints": ["Login succeeds"],
            },
            "## Acceptance Criteria\n1. Login works.",
        )

        self.assertIn("Ship login flow", prompt)
        self.assertIn("Users can sign in without errors.", prompt)
        self.assertIn("Draft contract:", prompt)
        self.assertIn('"verdict": "pass" | "fail"', prompt)

    def test_parse_contract_evaluation_returns_normalized_payload(self):
        parsed = contracts.parse_contract_evaluation(
            {
                "verdict": "PASS",
                "summary": "Looks good.",
                "issues": ["", "Need stronger maestro hint"],
            }
        )

        self.assertEqual(parsed, {
            "verdict": "pass",
            "summary": "Looks good.",
            "issues": ["Need stronger maestro hint"],
        })

    def test_parse_contract_evaluation_returns_none_for_invalid_payload(self):
        self.assertIsNone(contracts.parse_contract_evaluation({"summary": "missing verdict"}))
