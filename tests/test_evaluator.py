import unittest
from unittest.mock import Mock, patch

from cmux_harness import evaluator


class EvaluatorTests(unittest.TestCase):
    @patch("cmux_harness.evaluator.shutil.which", return_value=None)
    def test_is_maestro_available_returns_false_when_missing(self, mock_which):
        self.assertFalse(evaluator.is_maestro_available())
        mock_which.assert_called_once_with("maestro")

    def test_generate_maestro_flow_includes_app_id_and_assertions(self):
        flow = evaluator.generate_maestro_flow(
            "1. Welcome screen is visible\n- Account Summary is visible",
            app_id="com.test.app",
        )

        self.assertIn("appId: com.test.app", flow)
        self.assertIn("- launchApp", flow)
        self.assertIn('# Criterion: Welcome screen is visible', flow)
        self.assertIn('- assertVisible: "Welcome"', flow)
        self.assertIn('# Criterion: Account Summary is visible', flow)
        self.assertIn('- assertVisible: "Account"', flow)

    @patch("cmux_harness.evaluator.is_maestro_available", return_value=False)
    def test_run_tier2_maestro_skips_when_maestro_missing(self, mock_available):
        passed, output = evaluator.run_tier2_maestro("appId: com.test.app\n---\n- launchApp")

        self.assertTrue(passed)
        self.assertEqual(output, "Maestro not available - skipped")
        mock_available.assert_called_once_with()

    def test_run_tier1_build_calls_send_prompt_to_workspace(self):
        cmux_api_module = Mock()
        cmux_api_module.send_prompt_to_workspace.return_value = True

        passed, output = evaluator.run_tier1_build("ws-123", cmux_api_module)

        self.assertTrue(passed)
        self.assertEqual(output, "Build command sent")
        cmux_api_module.send_prompt_to_workspace.assert_called_once_with("ws-123", "/exp-project-run")


if __name__ == "__main__":
    unittest.main()
