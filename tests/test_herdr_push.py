import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from herdr_harness.push_notifications import APNsManager


TOKEN = "AB" * 32


class APNsManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "devices.json"
        self.manager = APNsManager(environ={}, store_path=self.path)

    def test_registration_is_persisted_without_echoing_full_token(self):
        result = self.manager.register(
            f"<{TOKEN}>",
            bundle_id="com.example.HerdrHarness",
            environment="sandbox",
        )
        reloaded = APNsManager(environ={}, store_path=self.path)

        self.assertTrue(result["registered"])
        self.assertEqual(result["device"]["tokenSuffix"], TOKEN.lower()[-8:])
        self.assertNotIn(TOKEN.lower(), str(result))
        self.assertEqual(reloaded.configuration()["deviceCount"], 1)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_duplicate_registration_updates_one_device_and_unregisters(self):
        self.manager.register(TOKEN, bundle_id="com.example.One", environment="sandbox")
        second = self.manager.register(TOKEN.lower(), bundle_id="com.example.Two", environment="production")
        removed = self.manager.unregister(TOKEN)

        self.assertEqual(second["deviceCount"], 1)
        self.assertTrue(removed["unregistered"])
        self.assertEqual(removed["deviceCount"], 0)

    def test_invalid_device_token_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "hexadecimal"):
            self.manager.register("ab" * 20 + "zz", bundle_id="com.example.App")

    def test_delivery_is_safely_disabled_without_credentials(self):
        self.manager.register(TOKEN, bundle_id="com.example.App", environment="sandbox")

        result = self.manager.notify_alert({"id": "alert_1", "title": "Done", "message": "Ready"})

        self.assertFalse(result["configured"])
        self.assertEqual(result["sent"], 0)
        self.assertTrue(result["errors"])

    def test_configured_delivery_builds_one_push_per_registered_device(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
                "HERDR_APNS_TOPIC": "com.example.App",
            },
            store_path=self.path,
        )
        manager.register(TOKEN, bundle_id="", environment="sandbox")

        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager, "_send", return_value=(True, "")
        ) as send:
            result = manager.notify_alert(
                {
                    "id": "alert_1",
                    "kind": "agent_done",
                    "title": "Builder finished",
                    "message": "Work completed.",
                    "workspaceId": "w1",
                    "paneId": "w1:p1",
                    "status": "done",
                },
                unread_count=3,
            )

        self.assertTrue(result["configured"])
        self.assertEqual(result["sent"], 1)
        payload = send.call_args.args[1]
        self.assertEqual(payload["aps"]["badge"], 3)
        self.assertEqual(payload["paneId"], "w1:p1")

    def test_async_delivery_deduplicates_alert_id(self):
        delivered = threading.Event()
        values = []
        with patch.object(self.manager, "notify_alert", return_value={"configured": False, "sent": 0, "errors": []}):
            first = self.manager.notify_alert_async(
                {"id": "alert_1"},
                unread_count=1,
                callback=lambda value: (values.append(value), delivered.set()),
            )
            second = self.manager.notify_alert_async({"id": "alert_1"}, unread_count=1)
            self.assertTrue(delivered.wait(1))

        self.assertTrue(first)
        self.assertFalse(second)
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0]["alertId"], "alert_1")


if __name__ == "__main__":
    unittest.main()
