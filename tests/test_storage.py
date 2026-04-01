import unittest
from cmux_harness.storage import parse_session_cost


class TestParseSessionCost(unittest.TestCase):

    def test_cost_line(self):
        text = "Some output\nMore output\nCost: $1.23"
        self.assertEqual(parse_session_cost(text), "$1.23")

    def test_money_bag_emoji(self):
        text = "Output\n\U0001f4b0$0.45"
        self.assertEqual(parse_session_cost(text), "$0.45")

    def test_block_format(self):
        text = "Status line\n$2.50 block"
        self.assertEqual(parse_session_cost(text), "$2.50")

    def test_bare_cost(self):
        text = "Some line\n$0.00"
        self.assertEqual(parse_session_cost(text), "$0.00")

    def test_no_cost(self):
        text = "Just a normal terminal\nWith no cost info"
        self.assertIsNone(parse_session_cost(text))

    def test_empty_input(self):
        self.assertIsNone(parse_session_cost(""))
        self.assertIsNone(parse_session_cost(None))

    def test_cost_in_last_5_lines(self):
        lines = [f"line {i}" for i in range(20)]
        lines.append("Cost: $3.75")
        text = "\n".join(lines)
        self.assertEqual(parse_session_cost(text), "$3.75")

    def test_cost_too_far_up(self):
        lines = ["Cost: $9.99"]
        lines += [f"line {i}" for i in range(10)]
        text = "\n".join(lines)
        self.assertIsNone(parse_session_cost(text))


if __name__ == "__main__":
    unittest.main()
