"""Tests for cmux_harness.approval (deprecated).

The approval module has been replaced by cmux_harness.severity.
See tests/test_severity.py for the new tests.
"""

import unittest


class TestApprovalDeprecated(unittest.TestCase):

    def test_module_imports(self):
        """Verify the deprecated module still imports without error."""
        import cmux_harness.approval  # noqa: F401


if __name__ == "__main__":
    unittest.main()
