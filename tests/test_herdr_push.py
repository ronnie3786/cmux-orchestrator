import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from herdr_harness.push_notifications import APNsManager, _APNsSendResult


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

    def test_live_activity_registration_is_private_persistent_and_token_scoped(self):
        registered = self.manager.register_live_activity(
            TOKEN,
            activity_id="pulse-123",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        reloaded = APNsManager(environ={}, store_path=self.path)

        self.assertTrue(registered["registered"])
        self.assertEqual(registered["activity"]["activityId"], "pulse-123")
        self.assertNotIn(TOKEN.lower(), str(registered))
        self.assertEqual(reloaded.configuration()["liveActivityCount"], 1)

        stale_token = reloaded.unregister_live_activity(
            "pulse-123",
            push_token="cd" * 32,
        )
        removed = reloaded.unregister_live_activity(
            "pulse-123",
            push_token=TOKEN,
        )

        self.assertFalse(stale_token["unregistered"])
        self.assertTrue(removed["unregistered"])
        self.assertEqual(removed["liveActivityCount"], 0)

    def test_live_activity_update_uses_activitykit_contract_and_aggregate_only_state(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
            },
            store_path=self.path,
        )
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-123",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        content_state = {
            "workspaceCount": 2,
            "paneCount": 6,
            "workingCount": 3,
            "attentionCount": 1,
            "readyCount": 1,
            "connection": "live",
            "phase": "attention",
            "updatedAt": 123,
        }

        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager, "_send_live_activity", return_value=(True, "")
        ) as send:
            result = manager.notify_herd_pulse(content_state)

        self.assertEqual(result["sent"], 1)
        payload = send.call_args.args[1]
        self.assertEqual(payload["aps"]["event"], "update")
        self.assertEqual(payload["aps"]["content-state"], content_state)
        self.assertEqual(send.call_args.args[3], 10)
        encoded = json.dumps(payload)
        self.assertNotIn("workspaceId", encoded)
        self.assertNotIn("paneId", encoded)
        self.assertNotIn("title", encoded)

    def test_live_activity_delivery_uses_activitykit_topic_and_headers(self):
        registration = {
            "token": TOKEN.lower(),
            "bundleId": "com.example.Herdr",
            "environment": "sandbox",
        }
        result = Mock(returncode=0, stdout="\n200", stderr="")

        with patch("herdr_harness.push_notifications.shutil.which", return_value="/usr/bin/curl"), patch(
            "herdr_harness.push_notifications.subprocess.run",
            return_value=result,
        ) as run:
            sent, error = self.manager._send_live_activity(
                registration,
                {"aps": {"event": "update"}},
                "jwt",
                10,
            )

        command = run.call_args.args[0]
        self.assertTrue(sent)
        self.assertEqual(error, "")
        self.assertIn("https://api.sandbox.push.apple.com/3/device/" + TOKEN.lower(), command)
        self.assertIn("apns-topic: com.example.Herdr.push-type.liveactivity", command)
        self.assertIn("apns-push-type: liveactivity", command)
        self.assertIn("apns-priority: 10", command)

    def test_terminal_apns_response_prunes_live_activity_without_exposing_token(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
            },
            store_path=self.path,
        )
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-expired",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        response = Mock(
            returncode=0,
            stdout='{"reason":"Unregistered","timestamp":123}\n410',
            stderr="",
        )

        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch(
            "herdr_harness.push_notifications.shutil.which",
            return_value="/usr/bin/curl",
        ), patch(
            "herdr_harness.push_notifications.subprocess.run",
            return_value=response,
        ):
            result = manager.notify_herd_pulse({"phase": "working"})

        self.assertEqual(result["sent"], 0)
        self.assertEqual(result["pruned"], 1)
        self.assertEqual(manager.configuration()["liveActivityCount"], 0)
        self.assertNotIn(TOKEN.lower(), json.dumps(result).lower())
        self.assertIn("HTTP 410 Unregistered", result["errors"][0])

    def test_bad_device_token_prunes_but_expired_provider_token_does_not(self):
        manager = self.manager
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-token",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager,
            "_send_live_activity",
            return_value=_APNsSendResult(
                False,
                "APNs rejected Live Activity: HTTP 400 BadDeviceToken",
                400,
                "BadDeviceToken",
            ),
        ):
            bad_device = manager.notify_herd_pulse({"phase": "working"})

        self.assertEqual(bad_device["pruned"], 1)
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-token",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager,
            "_send_live_activity",
            return_value=_APNsSendResult(
                False,
                "APNs rejected Live Activity: HTTP 403 ExpiredProviderToken",
                403,
                "ExpiredProviderToken",
            ),
        ):
            expired_provider = manager.notify_herd_pulse({"phase": "working"})

        self.assertEqual(expired_provider["pruned"], 0)
        self.assertEqual(manager.configuration()["liveActivityCount"], 1)

    def test_ready_live_activity_updates_are_high_priority(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
            },
            store_path=self.path,
        )
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-ready",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        state = {
            "workspaceCount": 1,
            "paneCount": 1,
            "workingCount": 0,
            "attentionCount": 0,
            "readyCount": 1,
            "connection": "live",
            "phase": "ready",
            "updatedAt": 123,
        }

        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager, "_send_live_activity", return_value=(True, "")
        ) as send:
            manager.notify_herd_pulse(state)

        self.assertEqual(send.call_args.args[3], 10)

    def test_live_activity_updates_deduplicate_unchanged_aggregate(self):
        delivered = threading.Event()
        values = []
        state = {
            "workspaceCount": 1,
            "paneCount": 2,
            "workingCount": 2,
            "attentionCount": 0,
            "readyCount": 0,
            "connection": "live",
            "phase": "working",
            "updatedAt": 123,
        }
        with patch.object(
            self.manager,
            "notify_herd_pulse",
            return_value={"configured": False, "sent": 0, "errors": []},
        ):
            first = self.manager.notify_herd_pulse_async(
                state,
                callback=lambda value: (values.append(value), delivered.set()),
            )
            second = self.manager.notify_herd_pulse_async(state)
            newer_timestamp = dict(state, updatedAt=999)
            third = self.manager.notify_herd_pulse_async(newer_timestamp)
            self.assertTrue(delivered.wait(1))

        self.assertTrue(first)
        self.assertFalse(second)
        self.assertFalse(third)
        self.assertEqual(len(values), 1)

    def test_live_activity_updates_are_ordered_and_pending_aggregates_coalesce(self):
        first_started = threading.Event()
        release_first = threading.Event()
        latest_finished = threading.Event()
        delivered = []

        def deliver(state, *, activity_id, timestamp):
            delivered.append((state["phase"], timestamp, activity_id))
            if len(delivered) == 1:
                first_started.set()
                self.assertTrue(release_first.wait(1))
            return {"configured": True, "sent": 1, "pruned": 0, "errors": []}

        first = {"phase": "working", "workingCount": 1, "updatedAt": 1}
        superseded = {"phase": "resting", "workingCount": 0, "updatedAt": 2}
        latest = {"phase": "attention", "attentionCount": 1, "updatedAt": 3}
        with patch.object(self.manager, "_deliver_herd_pulse", side_effect=deliver), patch(
            "herdr_harness.push_notifications.time.time",
            return_value=1000,
        ):
            self.assertTrue(self.manager.notify_herd_pulse_async(first))
            self.assertTrue(first_started.wait(1))
            self.assertTrue(self.manager.notify_herd_pulse_async(superseded))
            self.assertTrue(
                self.manager.notify_herd_pulse_async(
                    latest,
                    callback=lambda _result: latest_finished.set(),
                )
            )
            release_first.set()
            self.assertTrue(latest_finished.wait(1))

        self.assertEqual([item[0] for item in delivered], ["working", "attention"])
        self.assertGreater(delivered[1][1], delivered[0][1])

    def test_forced_activity_initial_state_bypasses_global_dedupe_and_coalescing(self):
        delivered = []
        finished = threading.Event()
        state = {"phase": "working", "workingCount": 1, "updatedAt": 1}

        def deliver(content_state, *, activity_id, timestamp):
            delivered.append((dict(content_state), activity_id, timestamp))
            return {"configured": True, "sent": 1, "pruned": 0, "errors": []}

        def did_finish(_result):
            if len(delivered) == 3:
                finished.set()

        with patch.object(self.manager, "_deliver_herd_pulse", side_effect=deliver):
            self.assertTrue(self.manager.notify_herd_pulse_async(state, callback=did_finish))
            self.assertTrue(
                self.manager.notify_herd_pulse_async(
                    state,
                    force=True,
                    activity_id="pulse-one",
                    callback=did_finish,
                )
            )
            self.assertTrue(
                self.manager.notify_herd_pulse_async(
                    state,
                    force=True,
                    activity_id="pulse-two",
                    callback=did_finish,
                )
            )
            self.assertTrue(finished.wait(1))

        self.assertEqual([item[1] for item in delivered], [None, "pulse-one", "pulse-two"])

    def test_provider_jwt_signing_is_single_flight(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
                "HERDR_APNS_TOPIC": "com.example.Herdr",
            },
            store_path=self.path,
        )
        all_entered = threading.Event()
        release_signing = threading.Event()
        entered_lock = threading.Lock()
        entered = 0
        results = []

        def worker():
            nonlocal entered
            with entered_lock:
                entered += 1
                if entered == 8:
                    all_entered.set()
            results.append(manager._auth_token())

        def sign(*_args, **_kwargs):
            self.assertTrue(release_signing.wait(1))
            return Mock(returncode=0, stdout=b"der", stderr=b"")

        with patch("herdr_harness.push_notifications.shutil.which", return_value="/usr/bin/openssl"), patch(
            "herdr_harness.push_notifications.subprocess.run",
            side_effect=sign,
        ) as signing, patch(
            "herdr_harness.push_notifications._der_to_raw_signature",
            return_value=b"s" * 64,
        ), patch(
            "herdr_harness.push_notifications.time.time",
            return_value=1000,
        ):
            threads = [threading.Thread(target=worker) for _ in range(8)]
            for thread in threads:
                thread.start()
            self.assertTrue(all_entered.wait(1))
            release_signing.set()
            for thread in threads:
                thread.join(1)

        self.assertEqual(signing.call_count, 1)
        self.assertEqual(len(results), 8)
        self.assertEqual(len({value[0] for value in results}), 1)
        self.assertTrue(all(error is None for _token, error in results))

    def test_live_activity_offline_state_is_stale_immediately(self):
        key = Path(self.temp.name) / "AuthKey.p8"
        key.write_text("fixture", encoding="utf-8")
        manager = APNsManager(
            environ={
                "HERDR_APNS_KEY_ID": "KEY123",
                "HERDR_APNS_TEAM_ID": "TEAM123",
                "HERDR_APNS_KEY_PATH": str(key),
            },
            store_path=self.path,
        )
        manager.register_live_activity(
            TOKEN,
            activity_id="pulse-offline",
            bundle_id="com.example.Herdr",
            environment="sandbox",
        )
        state = {
            "workspaceCount": 1,
            "paneCount": 2,
            "workingCount": 0,
            "attentionCount": 0,
            "readyCount": 0,
            "connection": "offline",
            "phase": "offline",
            "updatedAt": 123,
        }
        with patch.object(manager, "_auth_token", return_value=("jwt", None)), patch.object(
            manager, "_send_live_activity", return_value=(True, "")
        ) as send, patch("herdr_harness.push_notifications.time.time", return_value=500):
            manager.notify_herd_pulse(state)

        payload = send.call_args.args[1]
        self.assertEqual(payload["aps"]["stale-date"], 500)
        self.assertEqual(send.call_args.args[3], 5)


if __name__ == "__main__":
    unittest.main()
