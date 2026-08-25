import json
import tempfile
import unittest
from pathlib import Path

from herdr_harness.panes_seen import PaneFirstSeenStore


class SequenceClock:
    def __init__(self, *values):
        self.values = iter(values)

    def __call__(self):
        return next(self.values)


class PaneLifecycleStoreTests(unittest.TestCase):
    def test_tracks_activity_and_working_transitions_across_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store_path = Path(directory) / "panes.json"
            store = PaneFirstSeenStore(
                store_path=store_path,
                now=SequenceClock("t1", "t2", "t3", "t4", "t5"),
            )

            self.assertTrue(
                store.observe(
                    [{"pane_id": "w1:p1", "agent_status": "working", "revision": 1}]
                )
            )
            self.assertFalse(
                store.observe(
                    [{"pane_id": "w1:p1", "agent_status": "working", "revision": 1}]
                )
            )
            self.assertTrue(
                store.observe(
                    [{"pane_id": "w1:p1", "agent_status": "working", "revision": 2}]
                )
            )
            lifecycle = store.lifecycle_map()["w1:p1"]
            self.assertEqual(lifecycle["firstSeenAt"], "t1")
            self.assertEqual(lifecycle["lastActivityAt"], "t3")
            self.assertEqual(lifecycle["workingSince"], "t1")

            self.assertTrue(
                store.observe(
                    [{"pane_id": "w1:p1", "agent_status": "done", "revision": 3}]
                )
            )
            self.assertIsNone(store.lifecycle_map()["w1:p1"]["workingSince"])
            self.assertTrue(
                store.observe(
                    [{"pane_id": "w1:p1", "agent_status": "working", "revision": 4}]
                )
            )

            restarted = PaneFirstSeenStore(store_path=store_path)
            lifecycle = restarted.lifecycle_map()["w1:p1"]
            self.assertEqual(lifecycle["firstSeenAt"], "t1")
            self.assertEqual(lifecycle["lastActivityAt"], "t5")
            self.assertEqual(lifecycle["workingSince"], "t5")

    def test_migrates_v1_and_prunes_disappeared_panes(self):
        with tempfile.TemporaryDirectory() as directory:
            store_path = Path(directory) / "panes.json"
            store_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "firstSeen": {"w1:p1": "old-1", "w1:p2": "old-2"},
                    }
                ),
                encoding="utf-8",
            )

            store = PaneFirstSeenStore(store_path=store_path)

            self.assertEqual(store.first_seen_map()["w1:p1"], "old-1")
            migrated = json.loads(store_path.read_text(encoding="utf-8"))
            self.assertEqual(migrated["version"], 2)
            self.assertEqual(migrated["panes"]["w1:p1"]["lastActivityAt"], "old-1")
            self.assertTrue(store.prune({"w1:p2"}))
            self.assertEqual(set(store.lifecycle_map()), {"w1:p2"})


if __name__ == "__main__":
    unittest.main()
