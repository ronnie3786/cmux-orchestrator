import os
import sqlite3
import stat
import tempfile
import threading
import unittest
from pathlib import Path

from herdr_harness.active_work import ActiveWorkError, link_url, site_from_ticket, url
from herdr_harness.active_work_store import ActiveWorkRepository


EXPECTED_STAGES = [
    "start-ticket",
    "plan",
    "implement",
    "architect-code-review",
    "proof",
    "code-review-pre-pr",
    "pr",
    "pr-triage",
]


def jira_ticket(key="AGENTIC-575", *, title="Mobile API Impact Guard"):
    return {
        "key": key,
        "title": title,
        "status": "In Progress",
        "priority": "High",
        "issue_type": "Story",
        "url": f"https://jira.example.test/browse/{key}",
    }


def base_ingestion(item_id, *, key="cursor-1", observed="2026-08-26T16:00:00Z"):
    return {
        "source": "buzz",
        "idempotency_key": key,
        "observed_at": observed,
        "selector": {"work_item_id": item_id},
    }


class ActiveWorkStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "private" / "active-work.sqlite3"
        self.repo = ActiveWorkRepository(self.path)
        self.addCleanup(self.repo.close)

    def test_schema_is_versioned_private_and_seeds_exact_buzz_pipeline(self):
        self.assertEqual(self.repo.schema_version(), 1)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)

        board = self.repo.board_projection()
        pipeline = board["pipeline"]

        self.assertEqual(pipeline["slug"], "buzz-feature-work")
        self.assertEqual(pipeline["version"], 1)
        self.assertEqual([stage["stage_key"] for stage in pipeline["stages"]], EXPECTED_STAGES)
        self.assertEqual(
            [stage["stage_key"] for stage in pipeline["stages"] if stage["checkpoint_kind"] == "human"],
            ["plan", "proof", "code-review-pre-pr", "pr"],
        )

    def test_feature_starts_at_start_ticket_and_idea_can_remain_in_intake(self):
        feature = self.repo.create_item({"kind": "feature", "title": "Impact guard"})
        idea = self.repo.create_item({"kind": "idea", "title": "Project review memory"})

        self.assertEqual(feature["current_stage_key"], "start-ticket")
        self.assertEqual(feature["pipeline"]["stages"][0]["state"], "active")
        self.assertIsNone(idea["current_stage_key"])
        self.assertTrue(all(stage["state"] == "pending" for stage in idea["pipeline"]["stages"]))
        self.assertEqual(feature["setup_state"], "board_created")

    def test_patch_requires_matching_revision_and_preserves_newer_update(self):
        item = self.repo.create_item({"title": "Original"})
        patched = self.repo.patch_item(
            item["id"],
            {"title": "Revised", "expected_revision": item["revision"]},
        )

        self.assertEqual(patched["title"], "Revised")
        self.assertEqual(patched["revision"], item["revision"] + 1)
        with self.assertRaises(ActiveWorkError) as context:
            self.repo.patch_item(
                item["id"],
                {"summary": "stale write", "expected_revision": item["revision"]},
            )
        self.assertEqual(context.exception.status, 409)
        self.assertEqual(self.repo.item_projection(item["id"])["summary"], "")

    def test_transition_updates_whole_route_and_rejects_backward_motion(self):
        item = self.repo.create_item({"title": "Pipeline item"})
        moved = self.repo.transition(
            item["id"],
            {
                "to_stage_key": "proof",
                "expected_revision": item["revision"],
                "attention": "human",
                "note": "Proof packet is ready.",
            },
        )

        by_key = {stage["stage_key"]: stage for stage in moved["pipeline"]["stages"]}
        self.assertEqual(moved["current_stage_key"], "proof")
        self.assertTrue(all(by_key[key]["state"] == "complete" for key in EXPECTED_STAGES[:4]))
        self.assertEqual(by_key["proof"]["state"], "active")
        self.assertEqual(by_key["proof"]["checkpoint_state"], "pending")
        self.assertTrue(moved["needs_attention"])

        with self.assertRaises(ActiveWorkError) as context:
            self.repo.transition(
                moved["id"],
                {"to_stage_key": "plan", "expected_revision": moved["revision"]},
            )
        self.assertEqual(context.exception.code, "active_work_invalid_transition")

    def test_jira_setup_is_explicit_idempotent_and_remains_board_created(self):
        first = self.repo.setup_jira(jira_ticket())
        second_ticket = jira_ticket(title="Updated Jira title")
        second_ticket["status"] = "In Code Review"
        second = self.repo.setup_jira(second_ticket)

        self.assertTrue(first["created"])
        self.assertFalse(second["created"])
        self.assertEqual(first["item"]["id"], second["item"]["id"])
        self.assertEqual(second["item"]["setup_state"], "board_created")
        self.assertEqual(second["item"]["jira_links"][0]["status"], "In Code Review")
        self.assertEqual(len(self.repo.board_projection()["items"]), 1)

        candidates = self.repo.board_projection(
            [jira_ticket(), jira_ticket("IOSDOX-27458", title="Ask analytics audit")]
        )["jira_candidates"]
        self.assertEqual(candidates[0]["setup_state"], "board_created")
        self.assertEqual(candidates[0]["work_item_id"], first["item"]["id"])
        self.assertEqual(candidates[1]["setup_state"], "available")
        self.assertIsNone(candidates[1]["work_item_id"])

    def test_malformed_optional_urls_are_safe_and_never_crash_board_projection(self):
        malformed = jira_ticket()
        malformed["site"] = "https://["
        malformed["url"] = "https://["

        self.assertEqual(site_from_ticket(malformed), "default")
        setup = self.repo.setup_jira(malformed)
        self.assertTrue(setup["created"])
        self.assertEqual(setup["item"]["jira_links"][0]["url"], "")
        candidate = self.repo.board_projection([malformed])["jira_candidates"][0]
        self.assertEqual(candidate["work_item_id"], setup["item"]["id"])

        for validator in (url, link_url):
            with self.subTest(validator=validator.__name__):
                with self.assertRaises(ActiveWorkError):
                    validator("https://[", "broken URL")

    def test_ingestion_cannot_auto_create_an_untracked_jira_ticket(self):
        payload = {
            "source": "buzz",
            "idempotency_key": "scan-untracked",
            "observed_at": "2026-08-26T16:00:00Z",
            "selector": {"jira_key": "AGENTIC-999", "jira_site": "jira.example.test"},
            "item": {"title": "Must not appear"},
        }

        with self.assertRaises(ActiveWorkError) as context:
            self.repo.ingest(payload)

        self.assertEqual(context.exception.status, 404)
        self.assertEqual(self.repo.board_projection()["items"], [])

    def test_selector_requires_all_known_identifiers_to_agree_but_allows_new_channel(self):
        first = self.repo.setup_jira(jira_ticket())["item"]
        second = self.repo.create_item({"title": "Other work"})

        new_channel = base_ingestion(first["id"], key="selector-new-channel")
        new_channel["selector"].update(
            {"jira_key": "AGENTIC-575", "jira_site": "jira.example.test", "buzz_channel_id": "new-channel"}
        )
        new_channel["channel"] = {"external_id": "new-channel"}
        applied = self.repo.ingest(new_channel)
        self.assertEqual(applied["item"]["id"], first["id"])

        other_channel = base_ingestion(second["id"], key="selector-other-channel")
        other_channel["channel"] = {"external_id": "other-channel"}
        self.repo.ingest(other_channel)

        conflict = base_ingestion(first["id"], key="selector-conflict")
        conflict["selector"]["buzz_channel_id"] = "other-channel"
        with self.assertRaises(ActiveWorkError) as context:
            self.repo.ingest(conflict)
        self.assertEqual(context.exception.code, "active_work_selector_conflict")

        missing_jira = base_ingestion(first["id"], key="selector-missing-jira")
        missing_jira["selector"]["jira_key"] = "AGENTIC-999"
        with self.assertRaises(ActiveWorkError) as context:
            self.repo.ingest(missing_jira)
        self.assertEqual(context.exception.code, "active_work_selector_conflict")

    def test_ingestion_models_agents_sessions_and_threads_across_stages(self):
        item = self.repo.setup_jira(jira_ticket())["item"]
        payload = base_ingestion(item["id"])
        payload.update(
            {
                "current_stage_key": "implement",
                "item": {
                    "summary": "Guard every mobile API change.",
                    "next_action": "Coder finishes, then Architect reviews.",
                },
                "channel": {
                    "external_id": "channel-agentic-575",
                    "name": "AGENTIC-575 Mobile API Impact Guard",
                    "url": "https://buzz.example.test/channels/agentic-575",
                },
                "stages": [
                    {
                        "stage_key": "implement",
                        "state": "active",
                        "summary": "Implementation is underway.",
                        "content": {"commit": "abc123"},
                        "agents": [
                            {
                                "external_id": "buzz-driver-575",
                                "display_name": "Buzz Driver",
                                "kind": "buzz",
                                "status": "working",
                                "role": "driver",
                                "link_state": "active",
                            },
                            {
                                "external_id": "pi-coder-575",
                                "display_name": "Pi Coder",
                                "kind": "pi",
                                "status": "working",
                                "role": "coder",
                            },
                        ],
                        "pi_sessions": [
                            {
                                "external_id": "pi-session-575-a",
                                "agent_external_id": "pi-coder-575",
                                "title": "Implement API impact guard",
                                "provider": "pi",
                                "model": "gpt-5",
                                "status": "running",
                                "machine_id": "work-mac",
                                "workspace_id": "w1",
                                "pane_id": "w1:p1",
                                "native_session_id": "native-pi-575-a",
                                "role": "implementation",
                            }
                        ],
                    },
                    {
                        "stage_key": "architect-code-review",
                        "agents": [
                            {
                                "external_id": "buzz-driver-575",
                                "display_name": "Buzz Driver",
                                "kind": "buzz",
                                "status": "working",
                                "role": "driver",
                            }
                        ],
                        "pi_sessions": [
                            {
                                "external_id": "pi-session-575-a",
                                "agent_external_id": "pi-coder-575",
                                "title": "Implement API impact guard",
                                "provider": "pi",
                                "model": "gpt-5",
                                "status": "running",
                                "role": "handoff context",
                            }
                        ],
                        "threads": [
                            {
                                "external_id": "thread-review-575",
                                "title": "Architect review discussion",
                                "url": "https://buzz.example.test/threads/review-575",
                            }
                        ],
                    },
                ],
                "threads": [
                    {
                        "external_id": "thread-general-575",
                        "title": "Task discussion",
                        "url": "https://buzz.example.test/threads/general-575",
                    }
                ],
                "activity": [
                    {
                        "external_id": "event-575-1",
                        "stage_key": "implement",
                        "kind": "agent_started",
                        "actor_kind": "agent",
                        "actor_id": "buzz-driver-575",
                        "message": "Driver accepted ownership.",
                    }
                ],
            }
        )

        result = self.repo.ingest(payload)
        projected = result["item"]
        by_key = {stage["stage_key"]: stage for stage in projected["pipeline"]["stages"]}

        self.assertTrue(result["applied"])
        self.assertEqual(projected["current_stage_key"], "implement")
        self.assertEqual(projected["setup_state"], "ready")
        self.assertEqual(len(projected["agents"]), 2)
        self.assertEqual(len(projected["pi_sessions"]), 1)
        self.assertEqual(len(by_key["implement"]["pi_sessions"]), 1)
        self.assertEqual(len(by_key["architect-code-review"]["pi_sessions"]), 1)
        self.assertEqual(len(by_key["architect-code-review"]["buzz_threads"]), 1)
        self.assertEqual(len(projected["unscoped_threads"]), 1)
        self.assertIn("event-575-1", {event["source_event_id"] for event in projected["activity"]})
        self.assertEqual(
            projected["agents"][0]["stage_links"][0].keys(),
            {"stage_key", "link_role", "link_state", "attached_at", "detached_at"},
        )
        self.assertEqual(projected["stages"], projected["pipeline"]["stages"])

    def test_buzz_thread_deep_links_are_preserved(self):
        item = self.repo.create_item({"title": "Deep links"})
        payload = base_ingestion(item["id"])
        payload["threads"] = [
            {
                "external_id": "buzz-event-123",
                "title": "Planning discussion",
                "url": "buzz://message?channel=channel-1&event=event-123&root=root-100",
                "metadata": {
                    "channel_uuid": "channel-1",
                    "event_id": "event-123",
                    "root_event_id": "root-100",
                },
            }
        ]

        thread = self.repo.ingest(payload)["item"]["unscoped_threads"][0]

        self.assertEqual(
            thread["url"],
            "buzz://message?channel=channel-1&event=event-123&root=root-100",
        )
        self.assertEqual(thread["metadata"]["root_event_id"], "root-100")

    def test_partial_ingestion_preserves_omitted_source_fields_and_metadata(self):
        item = self.repo.create_item(
            {"title": "Merge target", "metadata": {"user_note": "keep me"}}
        )
        first = base_ingestion(item["id"], key="merge-1", observed="2026-08-26T16:00:00Z")
        first.update(
            {
                "item": {"metadata": {"buzz_workflow": {"status": "building", "phase": "build"}}},
                "channel": {
                    "external_id": "merge-channel",
                    "name": "Merge Channel",
                    "status": "active",
                    "metadata": {"visibility": "private", "topic": "impact guard"},
                },
                "stages": [
                    {
                        "stage_key": "implement",
                        "agents": [
                            {
                                "external_id": "merge-driver",
                                "display_name": "Merge Driver",
                                "status": "working",
                                "role_label": "driver",
                                "role": "driver",
                                "metadata": {"persona": "mobile"},
                            }
                        ],
                        "pi_sessions": [
                            {
                                "external_id": "merge-session",
                                "title": "Implementation",
                                "provider": "pi",
                                "model": "gpt-5",
                                "status": "running",
                                "pane_id": "w1:p1",
                                "role": "execution",
                                "metadata": {"floor": "local"},
                            }
                        ],
                        "threads": [
                            {
                                "external_id": "merge-thread",
                                "title": "Implementation discussion",
                                "url": "buzz://message?channel=merge-channel&id=" + "a" * 64,
                                "metadata": {"root_event_id": "a" * 64},
                            }
                        ],
                    }
                ],
            }
        )
        self.repo.ingest(first)

        partial = base_ingestion(item["id"], key="merge-2", observed="2026-08-26T16:01:00Z")
        partial.update(
            {
                "item": {"metadata": {"buzz_workflow": {"status": "reviewing"}}},
                "channel": {"external_id": "merge-channel", "metadata": {"member_count": 4}},
                "stages": [
                    {
                        "stage_key": "implement",
                        "agents": [{"external_id": "merge-driver", "role": "driver"}],
                        "pi_sessions": [{"external_id": "merge-session", "role": "execution"}],
                        "threads": [{"external_id": "merge-thread"}],
                    }
                ],
            }
        )
        projected = self.repo.ingest(partial)["item"]
        stage = next(value for value in projected["stages"] if value["stage_key"] == "implement")

        self.assertEqual(projected["metadata"]["user_note"], "keep me")
        self.assertEqual(projected["metadata"]["buzz_workflow"]["phase"], "build")
        self.assertEqual(projected["metadata"]["buzz_workflow"]["status"], "reviewing")
        self.assertEqual(projected["buzz_channels"][0]["name"], "Merge Channel")
        self.assertEqual(projected["buzz_channels"][0]["metadata"]["topic"], "impact guard")
        self.assertEqual(projected["buzz_channels"][0]["metadata"]["member_count"], 4)
        self.assertEqual(stage["agents"][0]["display_name"], "Merge Driver")
        self.assertEqual(stage["agents"][0]["status"], "working")
        self.assertEqual(stage["pi_sessions"][0]["model"], "gpt-5")
        self.assertEqual(stage["buzz_threads"][0]["title"], "Implementation discussion")

    def test_unscoped_thread_refresh_preserves_existing_stage_scope(self):
        item = self.repo.create_item({"title": "Thread scope"})
        scoped = base_ingestion(item["id"], key="thread-scope-1")
        scoped["stages"] = [
            {
                "stage_key": "plan",
                "threads": [
                    {
                        "external_id": "planning-thread",
                        "title": "Planning discussion",
                        "url": "buzz://message?channel=planning&id=" + "a" * 64,
                    }
                ],
            }
        ]
        self.repo.ingest(scoped)

        unscoped = base_ingestion(
            item["id"], key="thread-scope-2", observed="2026-08-26T16:01:00Z"
        )
        unscoped["threads"] = [{"external_id": "planning-thread", "status": "active"}]
        projected = self.repo.ingest(unscoped)["item"]
        plan = next(stage for stage in projected["stages"] if stage["stage_key"] == "plan")

        self.assertEqual(len(plan["buzz_threads"]), 1)
        self.assertEqual(plan["buzz_threads"][0]["title"], "Planning discussion")
        self.assertEqual(projected["unscoped_threads"], [])

    def test_sparse_observation_does_not_regress_route_or_future_stage_preparation(self):
        item = self.repo.create_item({"title": "Prepared route"})
        moved = self.repo.transition(
            item["id"],
            {"to_stage_key": "plan", "expected_revision": item["revision"]},
        )
        prepared = base_ingestion(moved["id"], key="future-1")
        prepared["stages"] = [
            {
                "stage_key": "proof",
                "state": "ready",
                "content": {"proof": {"packet": "ready", "owner": "agent"}},
            }
        ]
        self.repo.ingest(prepared)

        sparse = base_ingestion(
            moved["id"], key="future-2", observed="2026-08-26T16:01:00Z"
        )
        sparse["current_stage_key"] = "start-ticket"
        sparse["stages"] = [
            {
                "stage_key": "proof",
                "state": "pending",
                "content": {"proof": {"thread_count": 2}},
            }
        ]
        projected = self.repo.ingest(sparse)["item"]
        proof = next(stage for stage in projected["stages"] if stage["stage_key"] == "proof")

        self.assertEqual(projected["current_stage_key"], "plan")
        self.assertEqual(proof["state"], "ready")
        self.assertEqual(
            proof["content"]["proof"],
            {"packet": "ready", "owner": "agent", "thread_count": 2},
        )

    def test_done_items_remain_syncable_and_have_a_complete_final_stage(self):
        item = self.repo.create_item({"title": "Terminal work"})
        final = self.repo.transition(
            item["id"],
            {"to_stage_key": "pr-triage", "expected_revision": item["revision"]},
        )
        done = self.repo.patch_item(
            item["id"],
            {"lifecycle": "done", "expected_revision": final["revision"]},
        )
        final_stage = next(
            stage for stage in done["stages"] if stage["stage_key"] == "pr-triage"
        )

        self.assertEqual(final_stage["state"], "complete")
        self.assertEqual(
            [target["work_item_id"] for target in self.repo.sync_targets()["items"]],
            [item["id"]],
        )

        contradictory = base_ingestion(
            item["id"], key="terminal-contradiction", observed="2026-08-26T18:00:00Z"
        )
        contradictory.update(
            {"current_stage_key": "architect-code-review", "item": {"lifecycle": "active"}}
        )
        preserved = self.repo.ingest(contradictory)["item"]
        self.assertEqual(preserved["lifecycle"], "done")
        self.assertEqual(preserved["current_stage_key"], "pr-triage")

        archived = self.repo.patch_item(
            item["id"],
            {"lifecycle": "archived", "expected_revision": preserved["revision"]},
        )
        self.assertEqual(archived["lifecycle"], "archived")
        self.assertEqual(self.repo.sync_targets()["items"], [])

    def test_ingestion_rejects_done_lifecycle_before_final_stage(self):
        item = self.repo.create_item({"title": "Not terminal"})
        payload = base_ingestion(item["id"], key="bad-terminal")
        payload["item"] = {"lifecycle": "done"}

        with self.assertRaises(ActiveWorkError) as context:
            self.repo.ingest(payload)

        self.assertEqual(context.exception.code, "active_work_invalid_terminal_state")

    def test_idempotency_replays_same_payload_and_rejects_key_reuse(self):
        item = self.repo.create_item({"title": "Ingestion target"})
        payload = base_ingestion(item["id"])
        payload["item"] = {"summary": "First observation"}

        first = self.repo.ingest(payload)
        replay = self.repo.ingest(payload)
        conflict = dict(payload)
        conflict["item"] = {"summary": "Different payload"}

        self.assertTrue(first["applied"])
        self.assertTrue(replay["replayed"])
        self.assertEqual(first["receipt_id"], replay["receipt_id"])
        with self.assertRaises(ActiveWorkError) as context:
            self.repo.ingest(conflict)
        self.assertEqual(context.exception.code, "active_work_idempotency_conflict")

    def test_older_ingestion_is_receipted_but_cannot_regress_newer_state(self):
        item = self.repo.create_item({"title": "Stale-safe"})
        newer = base_ingestion(item["id"], key="newer", observed="2026-08-26T17:00:00Z")
        newer.update({"current_stage_key": "proof", "item": {"summary": "New state"}})
        older = base_ingestion(item["id"], key="older", observed="2026-08-26T16:00:00Z")
        older.update({"current_stage_key": "plan", "item": {"summary": "Old state"}})

        self.repo.ingest(newer)
        stale = self.repo.ingest(older)
        stale_replay = self.repo.ingest(older)

        self.assertTrue(stale["stale"])
        self.assertFalse(stale["applied"])
        self.assertTrue(stale_replay["replayed"])
        self.assertTrue(stale_replay["stale"])
        current = self.repo.item_projection(item["id"])
        self.assertEqual(current["current_stage_key"], "proof")
        self.assertEqual(current["summary"], "New state")

    def test_setup_state_tracks_channel_then_dedicated_driver(self):
        item = self.repo.create_item({"title": "Readiness"})
        channel = base_ingestion(item["id"], key="channel", observed="2026-08-26T16:00:00Z")
        channel["channel"] = {
            "external_id": "channel-readiness",
            "url": "https://buzz.example.test/channels/readiness",
        }
        linked = self.repo.ingest(channel)["item"]
        self.assertEqual(linked["setup_state"], "channel_linked")

        driver = base_ingestion(item["id"], key="driver", observed="2026-08-26T16:01:00Z")
        driver["stages"] = [
            {
                "stage_key": "start-ticket",
                "agents": [
                    {
                        "external_id": "driver-readiness",
                        "display_name": "Buzz Driver",
                        "role": "driver",
                    }
                ],
            }
        ]
        ready = self.repo.ingest(driver)["item"]
        self.assertEqual(ready["setup_state"], "ready")

        removed = base_ingestion(item["id"], key="remove-driver", observed="2026-08-26T16:02:00Z")
        removed["stages"] = [
            {
                "stage_key": "start-ticket",
                "agents": [
                    {
                        "external_id": "driver-readiness",
                        "display_name": "Buzz Driver",
                        "role": "driver",
                        "removed": True,
                    }
                ],
            }
        ]
        detached = self.repo.ingest(removed)["item"]
        self.assertEqual(detached["setup_state"], "channel_linked")

    def test_sync_targets_expose_only_stable_resolution_identifiers(self):
        tracked = self.repo.setup_jira(jira_ticket())["item"]
        payload = base_ingestion(tracked["id"])
        payload["channel"] = {"external_id": "channel-agentic-575"}
        self.repo.ingest(payload)

        target = self.repo.sync_targets()["items"][0]

        self.assertEqual(target["work_item_id"], tracked["id"])
        self.assertEqual(target["jira"], [{"site": "jira.example.test", "issue_key": "AGENTIC-575"}])
        self.assertEqual(
            target["buzz_channels"],
            [{"source": "buzz", "external_id": "channel-agentic-575"}],
        )
        self.assertNotIn("summary", target)

    def test_future_schema_and_symlink_database_are_rejected(self):
        future_path = Path(self.temp.name) / "future.sqlite3"
        connection = sqlite3.connect(future_path)
        connection.execute("PRAGMA user_version=99")
        connection.close()
        with self.assertRaises(ActiveWorkError) as future:
            ActiveWorkRepository(future_path)
        self.assertEqual(future.exception.code, "active_work_schema_newer")

        target = Path(self.temp.name) / "target.sqlite3"
        target.touch()
        symlink = Path(self.temp.name) / "linked.sqlite3"
        symlink.symlink_to(target)
        with self.assertRaises(ActiveWorkError) as unsafe:
            ActiveWorkRepository(symlink)
        self.assertEqual(unsafe.exception.code, "active_work_store_unsafe")

    def test_repository_serializes_concurrent_writers(self):
        errors = []

        def write_items(worker):
            try:
                for index in range(8):
                    self.repo.create_item({"title": f"worker-{worker}-{index}"})
                    self.repo.board_projection()
            except Exception as exc:  # pragma: no cover - assertion reports exact unexpected error
                errors.append(exc)

        threads = [threading.Thread(target=write_items, args=(worker,)) for worker in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)

        self.assertFalse(errors)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(len(self.repo.board_projection()["items"]), 32)


if __name__ == "__main__":
    unittest.main()
