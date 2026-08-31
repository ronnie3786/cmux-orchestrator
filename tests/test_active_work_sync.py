from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from typing import Any, Mapping
from unittest import mock

from herdr_harness.active_work_store import ActiveWorkRepository
from scripts import herdr_active_work_sync as sync


CHANNEL_ID = "11111111-1111-4111-8111-111111111111"
ROOT_EVENT_ID = "a" * 64
REPLY_EVENT_ID = "b" * 64
AGENT_PUBKEY = "c" * 64


class FakeResponse:
    def __init__(self, value: Mapping[str, Any]) -> None:
        self.body = json.dumps(value).encode("utf-8")

    def read(self, maximum: int = -1) -> bytes:
        return self.body if maximum < 0 else self.body[:maximum]

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: Any) -> None:
        return None


class RedirectedResponse(FakeResponse):
    status = 200

    def geturl(self) -> str:
        return "https://attacker.example.test/api/v1/active-work/sync-targets"


class RecordingHTTP:
    def __init__(self, targets: list[dict[str, Any]], *, replay_after_first: bool = False) -> None:
        self.targets = targets
        self.replay_after_first = replay_after_first
        self.requests: list[dict[str, Any]] = []
        self.post_count = 0

    def __call__(self, request: Any, *, timeout: float) -> FakeResponse:
        payload = json.loads(request.data.decode("utf-8")) if request.data else None
        self.requests.append(
            {
                "method": request.get_method(),
                "url": request.full_url,
                "headers": dict(request.header_items()),
                "payload": payload,
                "timeout": timeout,
            }
        )
        if request.get_method() == "GET":
            return FakeResponse(
                {"ok": True, "items": self.targets, "generated_at": "2026-08-26T20:00:00Z"}
            )
        if request.get_method() == "POST":
            self.post_count += 1
            replayed = self.replay_after_first and self.post_count > 1
            return FakeResponse(
                {
                    "applied": not replayed,
                    "replayed": replayed,
                    "stale": False,
                    "receipt_id": f"receipt-{self.post_count}",
                    "item": {},
                }
            )
        raise AssertionError(f"unexpected HTTP method {request.get_method()}")


class RecordingBuzzCLI:
    def __init__(self) -> None:
        self.calls: list[tuple[list[str], dict[str, Any]]] = []

    def __call__(self, command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        self.calls.append((list(command), dict(kwargs)))
        self.assert_safe_invocation(command, kwargs)
        operation = tuple(command[3:5])
        if operation == ("channels", "get"):
            value: Any = {
                "channel_id": CHANNEL_ID,
                "name": "iosdox-27492",
                "channel_type": "group",
                "archived": False,
            }
        elif operation == ("channels", "search"):
            value = [
                {
                    "channel_id": CHANNEL_ID,
                    "name": "iosdox-27492",
                    "channel_type": "group",
                    "visibility": "private",
                    "about": "CHANNEL_TEXT_MUST_NOT_BE_COPIED",
                    "purpose": "CHANNEL_PURPOSE_MUST_NOT_BE_COPIED",
                    "archived": False,
                }
            ]
        elif operation == ("channels", "members"):
            value = [{"pubkey": AGENT_PUBKEY, "role": "bot"}]
        elif operation == ("users", "get"):
            value = [
                {
                    "pubkey": AGENT_PUBKEY,
                    "display_name": "Build Bot",
                    "picture": "https://cdn.example.test/bot.png?token=SIGNED_AVATAR_SECRET",
                    "about": "PROFILE_BODY_MUST_NOT_BE_COPIED",
                    "system_prompt": "SYSTEM_PROMPT_MUST_NOT_BE_COPIED",
                    "private_key": "PROFILE_PRIVATE_KEY_MUST_NOT_BE_COPIED",
                }
            ]
        elif operation == ("messages", "get"):
            value = [
                {
                    "id": ROOT_EVENT_ID,
                    "kind": 45001,
                    "created_at": 1_777_000_000,
                    "tags": [],
                    "content": "ROOT_TRANSCRIPT_MUST_NOT_BE_COPIED",
                },
                {
                    "id": REPLY_EVENT_ID,
                    "kind": 9,
                    "created_at": 1_777_000_100,
                    "tags": [["e", ROOT_EVENT_ID, "", "root"]],
                    "content": "REPLY_TRANSCRIPT_MUST_NOT_BE_COPIED",
                },
            ]
        else:
            raise AssertionError(f"unexpected Buzz operation: {command}")
        return subprocess.CompletedProcess(command, 0, json.dumps(value).encode("utf-8"), b"")

    @staticmethod
    def assert_safe_invocation(command: list[str], kwargs: dict[str, Any]) -> None:
        if command[:3] != ["buzz", "--format", "json"]:
            raise AssertionError(f"Buzz was not invoked in JSON mode: {command}")
        if kwargs.get("shell"):
            raise AssertionError("Buzz subprocess must never use a shell")
        if not kwargs.get("timeout"):
            raise AssertionError("Buzz subprocess must have a timeout")


class StaticBuzz:
    def resolve_channel(self, _reference: Any) -> dict[str, Any]:
        return {
            "channelId": CHANNEL_ID,
            "name": "iosdox-27492",
            "type": "group",
            "visibility": "private",
            "archived": False,
        }

    def members(self, _channel_id: str) -> tuple[list[dict[str, Any]], bool]:
        return (
            [
                {
                    "pubkey": AGENT_PUBKEY,
                    "role": "bot",
                    "displayName": "Build Bot",
                    "avatarUrl": "https://cdn.example.test/bot.png",
                }
            ],
            False,
        )

    def channel_events(self, _channel_id: str) -> tuple[list[dict[str, Any]], bool]:
        return (
            [
                {
                    "id": REPLY_EVENT_ID,
                    "kind": 9,
                    "created_at": 1_777_000_100,
                    "tags": [["e", ROOT_EVENT_ID, "", "root"]],
                    "content": "TRANSCRIPT_MUST_NOT_BE_COPIED",
                }
            ],
            False,
        )


def target(ticket: str = "IOSDOX-27492") -> dict[str, Any]:
    return {
        "work_item_id": f"work-{ticket.lower()}",
        "kind": "feature",
        "title": "Agent pipeline board",
        "lifecycle": "active",
        "revision": 3,
        "jira": [{"site": "doximity.atlassian.net", "issue_key": ticket}],
        "buzz_channels": [{"source": "buzz", "external_id": CHANNEL_ID}],
    }


def ticket_state(ticket: str = "IOSDOX-27492") -> dict[str, Any]:
    return {
        "ticket": ticket,
        "kind": "feature",
        "stage": "implementation",
        "status": "working",
        "human_checkpoint": "proof",
        "buzz_channel": CHANNEL_ID,
        "buzz_agent": "Build Bot",
        "buzz_agent_pubkey": AGENT_PUBKEY,
        "workspace_id": "workspace-42",
        "workspace": "herdr-mac",
        "tab": "agentic-dev",
        "root_pane": "pane-7",
        "updated_at": "2026-08-26T20:01:02Z",
        "private_key_nsec": "STATE_PRIVATE_KEY_MUST_NOT_BE_COPIED",
        "api_token": "STATE_API_TOKEN_MUST_NOT_BE_COPIED",
        "system_prompt": "STATE_PROMPT_MUST_NOT_BE_COPIED",
        "transcript": "STATE_TRANSCRIPT_MUST_NOT_BE_COPIED",
        "content": "STATE_CONTENT_MUST_NOT_BE_COPIED",
    }


class ActiveWorkSyncTests(unittest.TestCase):
    def make_root(self, states: Mapping[str, Mapping[str, Any]]) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for key, state in states.items():
            directory = root / "tickets" / key
            directory.mkdir(parents=True)
            (directory / "state.json").write_text(json.dumps(state), encoding="utf-8")
        self.addCleanup(temporary.cleanup)
        return temporary

    def test_maps_all_legacy_stages_to_exact_canonical_keys(self) -> None:
        cases = {
            "start_ticket": "start-ticket",
            "planning": "plan",
            "implementation": "implement",
            "built": "architect-code-review",
            "validation-proof": "proof",
            "pre_pr": "code-review-pre-pr",
            "pull request": "pr",
            "teardown": "pr-triage",
        }
        self.assertEqual(tuple(sync.STAGE_KEYS), tuple(cases.values()))
        for legacy, expected in cases.items():
            with self.subTest(legacy=legacy):
                self.assertEqual(sync.canonical_stage(legacy), expected)
        for legacy in ("created", "floored", "cast-ready"):
            self.assertEqual(sync.canonical_stage(legacy), "start-ticket")
        for legacy in ("planned", "awaiting-approval"):
            self.assertEqual(sync.canonical_stage(legacy), "plan")
        for legacy in ("reviewing", "fixing"):
            self.assertEqual(sync.canonical_stage(legacy), "architect-code-review")

        self.assertEqual(
            sync.normalize_lifecycle("done", stage_key="architect-code-review"),
            "active",
        )
        self.assertEqual(sync.normalize_lifecycle("done", stage_key="pr-triage"), "done")
        self.assertEqual(sync.canonical_stage("shipped"), "pr")
        self.assertEqual(sync.canonical_stage("done"), "pr-triage")
        with self.assertRaises(sync.SyncError):
            sync.canonical_stage("surprise-stage")

    def test_canonical_buzz_deep_link_preserves_channel_event_and_root(self) -> None:
        link = sync.canonical_buzz_link(CHANNEL_ID, REPLY_EVENT_ID, ROOT_EVENT_ID)
        self.assertEqual(
            link,
            f"buzz://message?channel={CHANNEL_ID}&id={REPLY_EVENT_ID}&thread={ROOT_EVENT_ID}",
        )
        parsed = urllib.parse.urlsplit(link)
        query = urllib.parse.parse_qs(parsed.query)
        self.assertEqual(query["channel"], [CHANNEL_ID])
        self.assertEqual(query["id"], [REPLY_EVENT_ID])
        self.assertEqual(query["thread"], [ROOT_EVENT_ID])
        self.assertEqual(sync._https_avatar("https://["), "")

    def test_repeated_source_snapshot_has_identical_payload_hash_and_idempotency_key(self) -> None:
        state = ticket_state()
        parsed_target = sync.parse_sync_targets({"ok": True, "items": [target()]})["IOSDOX-27492"]
        first = sync.prepare_ingestion(state, parsed_target, StaticBuzz())
        second = sync.prepare_ingestion(state, parsed_target, StaticBuzz())
        self.assertEqual(first.payload_hash, second.payload_hash)
        self.assertEqual(first.idempotency_key, second.idempotency_key)
        self.assertEqual(first.request, second.request)
        self.assertTrue(first.idempotency_key.startswith("buzz:IOSDOX-27492:"))

    def test_terminal_source_state_emits_a_complete_final_stage(self) -> None:
        state = ticket_state()
        state.update({"stage": "done", "status": "done"})
        parsed_target = sync.parse_sync_targets({"ok": True, "items": [target()]})["IOSDOX-27492"]

        prepared = sync.prepare_ingestion(state, parsed_target, StaticBuzz())
        current = next(
            stage
            for stage in prepared.request["stages"]
            if stage["stage_key"] == "pr-triage"
        )

        self.assertEqual(prepared.request["item"]["lifecycle"], "done")
        self.assertEqual(prepared.request["current_stage_key"], "pr-triage")
        self.assertEqual(current["state"], "complete")

    def test_payload_whitelists_metadata_and_never_copies_secrets_or_transcripts(self) -> None:
        runner = RecordingBuzzCLI()
        buzz = sync.BuzzClient(run=runner)
        parsed_target = sync.parse_sync_targets({"ok": True, "items": [target()]})["IOSDOX-27492"]
        prepared = sync.prepare_ingestion(ticket_state(), parsed_target, buzz)
        serialized = sync.canonical_json(prepared.request)
        forbidden_values = (
            "STATE_PRIVATE_KEY_MUST_NOT_BE_COPIED",
            "STATE_API_TOKEN_MUST_NOT_BE_COPIED",
            "STATE_PROMPT_MUST_NOT_BE_COPIED",
            "STATE_TRANSCRIPT_MUST_NOT_BE_COPIED",
            "STATE_CONTENT_MUST_NOT_BE_COPIED",
            "CHANNEL_TEXT_MUST_NOT_BE_COPIED",
            "CHANNEL_PURPOSE_MUST_NOT_BE_COPIED",
            "PROFILE_BODY_MUST_NOT_BE_COPIED",
            "SYSTEM_PROMPT_MUST_NOT_BE_COPIED",
            "PROFILE_PRIVATE_KEY_MUST_NOT_BE_COPIED",
            "ROOT_TRANSCRIPT_MUST_NOT_BE_COPIED",
            "REPLY_TRANSCRIPT_MUST_NOT_BE_COPIED",
            "SIGNED_AVATAR_SECRET",
        )
        for forbidden in forbidden_values:
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, serialized)

        stage = next(
            item for item in prepared.request["stages"] if item["stage_key"] == "implement"
        )
        self.assertEqual(stage["agents"][0]["external_id"], AGENT_PUBKEY)
        self.assertEqual(stage["agents"][0]["role"], "driver")
        self.assertEqual(stage["agents"][0]["link_state"], "active")
        self.assertEqual(
            stage["agents"][0]["avatar_url"], "https://cdn.example.test/bot.png"
        )
        thread = prepared.request["threads"][0]
        self.assertEqual(thread["external_id"], ROOT_EVENT_ID)
        self.assertEqual(thread["channel_external_id"], CHANNEL_ID)
        self.assertEqual(thread["metadata"]["channel_uuid"], CHANNEL_ID)
        self.assertEqual(thread["metadata"]["event_id"], REPLY_EVENT_ID)
        self.assertEqual(thread["metadata"]["root_event_id"], ROOT_EVENT_ID)
        self.assertEqual(prepared.request["channel"]["metadata"]["channel_uuid"], CHANNEL_ID)
        sync.assert_secret_free(prepared.request)

    def test_untracked_ticket_never_invokes_buzz_or_posts_or_creates(self) -> None:
        state = ticket_state("IOSDOX-99999")
        temporary = self.make_root({"IOSDOX-99999": state})
        http = RecordingHTTP([target("IOSDOX-27492")])
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)

        def fail_buzz(*_args: Any, **_kwargs: Any) -> Any:
            raise AssertionError("Buzz must not be called for an untracked ticket")

        summary, plans, errors = sync.run_sync(
            Path(temporary.name), herdr, sync.BuzzClient(run=fail_buzz)
        )
        self.assertEqual(summary.untracked, 1)
        self.assertEqual(summary.tracked, 0)
        self.assertEqual(summary.ingested, 0)
        self.assertEqual(summary.failed, 0)
        self.assertEqual(plans, [])
        self.assertEqual(errors, [])
        self.assertEqual([entry["method"] for entry in http.requests], ["GET"])
        self.assertTrue(http.requests[0]["url"].endswith(sync.SYNC_TARGETS_PATH))

    def test_invalid_ticket_directory_is_skipped_and_sync_continues(self) -> None:
        temporary = self.make_root(
            {
                "IDEA-native-bridge-text-selection": ticket_state(),
                "IOSDOX-27492": ticket_state(),
            }
        )
        http = RecordingHTTP([target()])
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)
        summary, plans, errors = sync.run_sync(
            Path(temporary.name), herdr, sync.BuzzClient(run=RecordingBuzzCLI())
        )
        self.assertEqual(summary.discovered, 2)
        self.assertEqual(summary.untracked, 1)
        self.assertEqual(summary.tracked, 1)
        self.assertEqual(summary.failed, 0)
        self.assertEqual(len(errors), 1)
        self.assertIn("IDEA-native-bridge-text-selection", errors[0])
        self.assertEqual(len(plans), 1)

    def test_idea_directory_targets_board_item_by_work_item_id(self) -> None:
        state = ticket_state()
        state.pop("ticket")
        state.update(
            {
                "kind": "idea",
                "stage": "implementing",
                "status": "in-progress",
                "floor": "devbox",
                "workspace": "wZ",
                "tab": "wZ:t1",
                "root_pane": "wZ:p2",
                "active_work_id": "work-idea-native-bridge",
            }
        )
        temporary = self.make_root({"IDEA-native-bridge-text-selection": state})
        idea_target = {
            "work_item_id": "work-idea-native-bridge",
            "kind": "idea",
            "title": "Native text selection (Native Bridge)",
            "lifecycle": "active",
            "revision": 1,
            "jira": [],
            "buzz_channels": [{"source": "buzz", "external_id": CHANNEL_ID}],
        }
        http = RecordingHTTP([idea_target])
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)
        summary, plans, errors = sync.run_sync(
            Path(temporary.name), herdr, sync.BuzzClient(run=RecordingBuzzCLI())
        )

        self.assertEqual(summary.tracked, 1)
        self.assertEqual(summary.ingested, 1)
        self.assertEqual(summary.failed, 0)
        self.assertEqual(errors, [])
        post = next(entry for entry in http.requests if entry["method"] == "POST")
        self.assertEqual(
            post["payload"]["selector"],
            {"work_item_id": "work-idea-native-bridge", "buzz_channel_id": CHANNEL_ID},
        )
        stage = next(
            stage
            for stage in post["payload"]["stages"]
            if stage["stage_key"] == "implement"
        )
        self.assertEqual(len(stage["pi_sessions"]), 1)
        session = stage["pi_sessions"][0]
        self.assertEqual(session["pane_id"], "devbox:wZ:p2")
        self.assertEqual(session["metadata"]["floor"], "devbox")
        self.assertTrue(
            session["external_id"].startswith("state:IDEA-native-bridge-text-selection:")
        )

    def test_idea_directory_without_active_work_id_stays_untracked(self) -> None:
        temporary = self.make_root(
            {
                "IDEA-native-bridge-text-selection": ticket_state(),
                "IOSDOX-27492": ticket_state(),
            }
        )
        http = RecordingHTTP([target()])
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)
        summary, plans, errors = sync.run_sync(
            Path(temporary.name), herdr, sync.BuzzClient(run=RecordingBuzzCLI())
        )
        self.assertEqual(summary.discovered, 2)
        self.assertEqual(summary.untracked, 1)
        self.assertEqual(summary.tracked, 1)
        self.assertEqual(summary.failed, 0)
        self.assertEqual(len(errors), 1)
        self.assertIn("IDEA-native-bridge-text-selection", errors[0])
        self.assertEqual(len(plans), 1)

    def test_dry_run_resolves_source_but_does_not_post(self) -> None:
        temporary = self.make_root({"IOSDOX-27492": ticket_state()})
        http = RecordingHTTP([target()])
        runner = RecordingBuzzCLI()
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)
        summary, plans, errors = sync.run_sync(
            Path(temporary.name), herdr, sync.BuzzClient(run=runner), dry_run=True
        )
        self.assertEqual(summary.tracked, 1)
        self.assertEqual(summary.ingested, 0)
        self.assertEqual(summary.failed, 0)
        self.assertEqual(errors, [])
        self.assertEqual(plans[0]["action"], "would-ingest")
        self.assertEqual([entry["method"] for entry in http.requests], ["GET"])
        self.assertGreater(len(runner.calls), 0)

    def test_http_contract_and_replay_are_idempotent(self) -> None:
        temporary = self.make_root({"IOSDOX-27492": ticket_state()})
        http = RecordingHTTP([target()], replay_after_first=True)
        runner = RecordingBuzzCLI()
        herdr = sync.HerdrClient("http://127.0.0.1:9092", token="HERDR_SECRET", open_url=http)
        buzz = sync.BuzzClient(run=runner)

        first, first_plans, first_errors = sync.run_sync(Path(temporary.name), herdr, buzz)
        second, second_plans, second_errors = sync.run_sync(Path(temporary.name), herdr, buzz)

        self.assertEqual(first_errors, [])
        self.assertEqual(second_errors, [])
        self.assertEqual(first.ingested, 1)
        self.assertEqual(first_plans[0]["action"], "ingested")
        self.assertEqual(second.unchanged, 1)
        self.assertEqual(second_plans[0]["action"], "replayed")
        posts = [entry for entry in http.requests if entry["method"] == "POST"]
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0]["url"], "http://127.0.0.1:9092" + sync.INGESTIONS_PATH)
        self.assertEqual(posts[0]["payload"], posts[1]["payload"])
        self.assertEqual(
            posts[0]["payload"]["idempotency_key"], posts[1]["payload"]["idempotency_key"]
        )
        self.assertEqual(
            posts[0]["headers"]["Idempotency-key"],
            posts[0]["payload"]["idempotency_key"],
        )
        self.assertEqual(posts[0]["headers"]["Authorization"], "Bearer HERDR_SECRET")
        self.assertNotIn("HERDR_SECRET", sync.canonical_json(posts[0]["payload"]))

    def test_http_transport_rejects_non_loopback_plaintext_and_redirects(self) -> None:
        with self.assertRaises(sync.SyncError):
            sync.HerdrClient("http://herdr.example.test:9092")
        with self.assertRaises(sync.SyncError):
            sync.HerdrClient("http://100.64.0.10:9092")

        client = sync.HerdrClient(
            "http://127.0.0.1:9092",
            token="SCOPED_SECRET",
            open_url=lambda *_args, **_kwargs: RedirectedResponse({"ok": True, "items": []}),
        )
        with self.assertRaisesRegex(sync.SyncError, "redirects are not allowed"):
            client.sync_targets()

    def test_private_token_file_is_supported_for_launchd(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        token_path = Path(temporary.name) / "active-work.token"
        token_path.write_text("private-launchd-token\n", encoding="utf-8")
        token_path.chmod(0o600)

        self.assertEqual(sync.load_auth_token_file(str(token_path)), "private-launchd-token")
        self.assertEqual(
            sync.resolve_auth_token(
                environ={"HERDR_ACTIVE_WORK_TOKEN_FILE": str(token_path)}
            ),
            "private-launchd-token",
        )
        self.assertEqual(
            sync.resolve_auth_token(
                token_file=str(token_path),
                environ={"HERDR_ACTIVE_WORK_TOKEN_FILE": str(token_path)},
            ),
            "private-launchd-token",
        )
        self.assertEqual(
            sync.parse_args(["--token-file", str(token_path)]).token_file,
            str(token_path),
        )

    def test_token_configuration_rejects_ambiguous_direct_and_file_sources(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        first = Path(temporary.name) / "first.token"
        second = Path(temporary.name) / "second.token"
        for path in (first, second):
            path.write_text("private-token", encoding="utf-8")
            path.chmod(0o600)

        for variable in ("HERDR_ACTIVE_WORK_TOKEN", "HERDR_HARNESS_API_TOKEN"):
            with self.subTest(variable=variable):
                with self.assertRaisesRegex(sync.SyncError, "either.*file.*environment"):
                    sync.resolve_auth_token(
                        token_file=str(first),
                        environ={variable: "direct-token"},
                    )
        with self.assertRaisesRegex(sync.SyncError, "multiple Active Work token files"):
            sync.resolve_auth_token(
                token_file=str(first),
                environ={"HERDR_ACTIVE_WORK_TOKEN_FILE": str(second)},
            )

    def test_token_file_rejects_unsafe_type_owner_permissions_size_and_content(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)

        target = root / "target.token"
        target.write_text("private-token", encoding="utf-8")
        target.chmod(0o600)
        symlink = root / "linked.token"
        symlink.symlink_to(target)
        with self.assertRaisesRegex(sync.SyncError, "regular file, not a symlink"):
            sync.load_auth_token_file(str(symlink))
        with self.assertRaisesRegex(sync.SyncError, "regular file, not a symlink"):
            sync.load_auth_token_file(str(root))

        for mode in (0o640, 0o604):
            with self.subTest(mode=oct(mode)):
                target.chmod(mode)
                with self.assertRaisesRegex(sync.SyncError, "group or other"):
                    sync.load_auth_token_file(str(target))
        target.chmod(0o600)

        with mock.patch.object(sync.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(sync.SyncError, "another user"):
                sync.load_auth_token_file(str(target))

        target.write_bytes(b"x" * (sync.MAX_AUTH_TOKEN_FILE_BYTES + 1))
        target.chmod(0o600)
        with self.assertRaisesRegex(sync.SyncError, "exceeds"):
            sync.load_auth_token_file(str(target))

        target.write_text("\n", encoding="utf-8")
        target.chmod(0o600)
        with self.assertRaisesRegex(sync.SyncError, "is empty"):
            sync.load_auth_token_file(str(target))

    def test_direct_and_file_tokens_are_bounded_and_header_safe(self) -> None:
        with self.assertRaisesRegex(sync.SyncError, "exceeds"):
            sync.resolve_auth_token(
                environ={"HERDR_ACTIVE_WORK_TOKEN": "x" * (sync.MAX_AUTH_TOKEN_BYTES + 1)}
            )
        with self.assertRaisesRegex(sync.SyncError, "without whitespace"):
            sync.resolve_auth_token(environ={"HERDR_ACTIVE_WORK_TOKEN": "two tokens"})

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        token_path = Path(temporary.name) / "newline.token"
        token_path.write_text("first\nsecond\n", encoding="utf-8")
        token_path.chmod(0o600)
        with self.assertRaisesRegex(sync.SyncError, "without whitespace"):
            sync.load_auth_token_file(str(token_path))

    def test_private_buzz_key_file_is_supported_and_ambiguity_is_rejected(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        key_path = Path(temporary.name) / "buzz-private-key"
        private_key = "d" * 64
        key_path.write_text(private_key + "\n", encoding="utf-8")
        key_path.chmod(0o600)

        self.assertEqual(sync.load_buzz_private_key_file(str(key_path)), private_key)
        self.assertEqual(
            sync.resolve_buzz_private_key(
                environ={"BUZZ_PRIVATE_KEY_FILE": str(key_path)}
            ),
            private_key,
        )
        self.assertEqual(
            sync.resolve_buzz_private_key(environ={"BUZZ_PRIVATE_KEY": private_key}),
            private_key,
        )
        self.assertEqual(
            sync.parse_args(["--buzz-private-key-file", str(key_path)]).buzz_private_key_file,
            str(key_path),
        )
        with self.assertRaisesRegex(sync.SyncError, "either.*file.*BUZZ_PRIVATE_KEY"):
            sync.resolve_buzz_private_key(
                private_key_file=str(key_path),
                environ={"BUZZ_PRIVATE_KEY": private_key},
            )

    def test_buzz_private_key_only_reaches_the_buzz_child_environment(self) -> None:
        private_key = "e" * 64
        captured: dict[str, Any] = {}

        def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
            captured["command"] = command
            captured["environment"] = kwargs.get("env")
            return subprocess.CompletedProcess(command, 0, b"{}", b"")

        with mock.patch.dict(
            os.environ,
            {
                "BUZZ_RELAY_URL": "wss://relay.example.test",
                "HERDR_ACTIVE_WORK_TOKEN": "must-not-reach-buzz",
            },
            clear=True,
        ):
            client = sync.BuzzClient(run=run, private_key=private_key)
            self.assertEqual(client._json(["channels", "get", "--channel", CHANNEL_ID]), {})
            self.assertNotIn("BUZZ_PRIVATE_KEY", os.environ)

        self.assertNotIn(private_key, captured["command"])
        self.assertEqual(captured["environment"]["BUZZ_PRIVATE_KEY"], private_key)
        self.assertNotIn("HERDR_ACTIVE_WORK_TOKEN", captured["environment"])
        self.assertEqual(
            captured["environment"]["BUZZ_RELAY_URL"],
            "wss://relay.example.test",
        )

        def echo_secret(command: list[str], **_kwargs: Any) -> subprocess.CompletedProcess[bytes]:
            return subprocess.CompletedProcess(command, 3, b"", private_key.encode("ascii"))

        with self.assertRaises(sync.SyncError) as context:
            sync.BuzzClient(run=echo_secret, private_key=private_key)._json(
                ["channels", "get", "--channel", CHANNEL_ID]
            )
        self.assertNotIn(private_key, str(context.exception))

    def test_prepared_request_is_accepted_by_real_ingestion_contract(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        repository = ActiveWorkRepository(Path(temporary.name) / "active-work.sqlite3")
        self.addCleanup(repository.close)
        setup = repository.setup_jira(
            {
                "key": "IOSDOX-27492",
                "title": "Agent pipeline board",
                "status": "In Progress",
                "priority": "High",
                "issue_type": "Story",
                "url": "https://doximity.atlassian.net/browse/IOSDOX-27492",
            }
        )
        parsed_target = sync.SyncTarget(
            ticket_key="IOSDOX-27492",
            work_item_id=setup["item"]["id"],
            title="Agent pipeline board",
            kind="feature",
            jira_site="doximity.atlassian.net",
        )
        prepared = sync.prepare_ingestion(ticket_state(), parsed_target, StaticBuzz())

        first = repository.ingest(prepared.request)
        replay = repository.ingest(prepared.request)

        self.assertTrue(first["applied"])
        self.assertTrue(replay["replayed"])
        self.assertEqual(first["receipt_id"], replay["receipt_id"])
        projected = first["item"]
        self.assertEqual(projected["setup_state"], "ready")
        self.assertEqual(projected["current_stage_key"], "implement")
        self.assertEqual(projected["agents"][0]["stage_links"][0]["link_role"], "driver")
        thread = projected["unscoped_threads"][0]
        self.assertEqual(thread["metadata"]["channel_uuid"], CHANNEL_ID)
        self.assertEqual(
            thread["url"],
            f"buzz://message?channel={CHANNEL_ID}&id={REPLY_EVENT_ID}&thread={ROOT_EVENT_ID}",
        )

    def test_default_root_and_env_overrides_are_supported(self) -> None:
        old = os.environ.get("BUZZ_WORKFLOW_ROOT")
        os.environ["BUZZ_WORKFLOW_ROOT"] = "/private/tmp/custom-buzz-workflow"
        try:
            args = sync.parse_args(["--dry-run", "--ticket", "iosdox-27492"])
        finally:
            if old is None:
                os.environ.pop("BUZZ_WORKFLOW_ROOT", None)
            else:
                os.environ["BUZZ_WORKFLOW_ROOT"] = old
        self.assertEqual(args.workflow_root, "/private/tmp/custom-buzz-workflow")
        self.assertEqual(args.ticket, "IOSDOX-27492")
        self.assertTrue(args.dry_run)


if __name__ == "__main__":
    unittest.main()
