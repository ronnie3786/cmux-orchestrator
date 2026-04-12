import subprocess
import unittest
from pathlib import Path


class TestOrchestratorUi(unittest.TestCase):

    def test_contract_review_ui_regressions(self):
        script = Path("tests/orchestrator_contract_review_ui.test.mjs")
        result = subprocess.run(
            ["node", "--test", str(script)],
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode != 0:
            self.fail(
                "Node UI regression tests failed.\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
