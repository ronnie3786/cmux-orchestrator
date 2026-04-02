import threading
import time
import unittest

from cmux_harness.workspace_mutex import WorkspaceMutex


class TestWorkspaceMutex(unittest.TestCase):

    def test_acquire_and_release_basic_flow(self):
        mutex = WorkspaceMutex()

        self.assertTrue(mutex.acquire("ws-1"))
        mutex.release("ws-1")
        self.assertTrue(mutex.acquire("ws-1", blocking=False))
        mutex.release("ws-1")

    def test_lock_blocks_second_acquire(self):
        mutex = WorkspaceMutex()
        started = threading.Event()
        finished = threading.Event()
        results = []

        def worker():
            started.set()
            results.append(mutex.acquire("ws-1", timeout=0.05))
            finished.set()

        self.assertTrue(mutex.acquire("ws-1"))
        thread = threading.Thread(target=worker)
        thread.start()
        started.wait(timeout=1)
        finished.wait(timeout=1)
        mutex.release("ws-1")
        thread.join(timeout=1)

        self.assertEqual(results, [False])

    def test_context_manager_acquires_and_releases(self):
        mutex = WorkspaceMutex()

        with mutex.context("ws-1"):
            self.assertFalse(mutex.acquire("ws-1", blocking=False))

        self.assertTrue(mutex.acquire("ws-1", blocking=False))
        mutex.release("ws-1")

    def test_set_cooldown_and_is_in_cooldown(self):
        mutex = WorkspaceMutex()

        mutex.set_cooldown("ws-1", 0.2)

        self.assertTrue(mutex.is_in_cooldown("ws-1"))

    def test_cooldown_expires_after_specified_time(self):
        mutex = WorkspaceMutex()

        mutex.set_cooldown("ws-1", 0.05)
        time.sleep(0.08)

        self.assertFalse(mutex.is_in_cooldown("ws-1"))

    def test_different_workspace_ids_get_independent_locks(self):
        mutex = WorkspaceMutex()

        self.assertTrue(mutex.acquire("ws-1"))
        self.assertTrue(mutex.acquire("ws-2", blocking=False))

        mutex.release("ws-2")
        mutex.release("ws-1")


if __name__ == "__main__":
    unittest.main()
