import copy
import http.client
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

from herdr_harness import cmux_tools
from herdr_harness.active_work_store import ActiveWorkRepository
from herdr_harness.events import EventBroker
from herdr_harness.server import (
    ActiveWorkAuthConfigurationError,
    _configured_manage_token,
    make_handler,
    make_server,
)
from herdr_harness.service import HerdrService


MAIN_TOKEN = "active-work-main-token"
MANAGE_TOKEN = "active-work-manage-token"
INGEST_TOKEN = "active-work-ingest-token"


def jira_ticket(key="AGENTIC-575", *, title="Mobile API Impact Guard"):
    return {
        "key": key,
        "projectKey": key.split("-", 1)[0],
        "title": title,
        "status": "In Progress",
        "priority": "High",
        "issueType": "Story",
        "url": f"https://jira.example.test/browse/{key}",
    }


class FakeHerdrClient:
    socket_path = "/private/tmp/active-work-integration.sock"
    session = "active-work-integration"

    def snapshot(self):
        return {
            "version": "0.8.0",
            "protocol": 19,
            "workspaces": [],
            "tabs": [],
            "panes": [],
            "agents": [],
            "layouts": [],
        }

    def request(self, _method, _params):
        return {"type": "ok"}

    def subscribe_forever(self, *_args, **_kwargs):
        return None


class QuietPiSemantic:
    def stop(self):
        return None

    def close(self):
        return None


class FakeActiveWorkTools:
    def __init__(self):
        self.assigned_tickets = [jira_ticket()]
        self.issue = jira_ticket()
        self.assigned_error = None
        self.calls = []

    def jira_assigned(self, project=None, limit=50):
        self.calls.append(("jira_assigned", project, limit))
        if self.assigned_error is not None:
            raise self.assigned_error
        return {
            "ok": True,
            "site": "jira.example.test",
            "project": project,
            "projects": ["AGENTIC"],
            "tickets": copy.deepcopy(self.assigned_tickets),
        }

    def jira_issue(self, query):
        self.calls.append(("jira_issue", query))
        ticket = copy.deepcopy(self.issue)
        ticket["key"] = query
        ticket["projectKey"] = query.split("-", 1)[0]
        ticket["url"] = f"https://jira.example.test/browse/{query}"
        return {"ok": True, "site": "jira.example.test", "ticket": ticket}


class ActiveWorkIntegrationFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.database_path = Path(self.temporary.name) / "private" / "active-work.sqlite3"
        self.repository = ActiveWorkRepository(self.database_path)
        self.tools = FakeActiveWorkTools()
        self.broker = EventBroker()
        self.service = HerdrService(
            FakeHerdrClient(),
            broker=self.broker,
            environ={
                "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": MANAGE_TOKEN,
                "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": INGEST_TOKEN,
            },
            tools=self.tools,
            pi_semantic=QuietPiSemantic(),
            active_work=self.repository,
        )

    def tearDown(self):
        self.service.stop()
        self.repository.close()
        self.temporary.cleanup()


class ActiveWorkServiceIntegrationTests(ActiveWorkIntegrationFixture, unittest.TestCase):
    def test_durable_board_survives_jira_outage(self):
        tracked = self.repository.create_item(
            {
                "kind": "feature",
                "title": "Persisted route",
                "summary": "This item belongs to Herdr, not Jira.",
            }
        )
        self.tools.assigned_error = cmux_tools.CmuxToolsError(
            "Jira is unavailable",
            code="jira_unavailable",
            status=503,
        )

        board = self.service.active_work_board()

        self.assertTrue(board["ok"])
        self.assertEqual([item["id"] for item in board["items"]], [tracked["id"]])
        self.assertEqual(board["items"][0]["summary"], "This item belongs to Herdr, not Jira.")
        self.assertEqual(board["jira_candidates"], [])
        self.assertEqual(
            board["jira_candidates_status"],
            {"ok": False, "error": "Jira is unavailable"},
        )

        # The failed enrichment call cannot damage the durable projection.
        persisted = ActiveWorkRepository(self.database_path)
        self.addCleanup(persisted.close)
        self.assertEqual(persisted.item_projection(tracked["id"])["title"], "Persisted route")

    def test_observing_assigned_jira_candidates_never_creates_work(self):
        self.tools.assigned_tickets = [
            jira_ticket("AGENTIC-575"),
            jira_ticket("IOSDOX-27458", title="Ask analytics audit"),
        ]

        first = self.service.active_work_board()
        second = self.service.active_work_board()

        self.assertEqual(first["items"], [])
        self.assertEqual(second["items"], [])
        self.assertEqual(
            {candidate["key"]: candidate["setup_state"] for candidate in first["jira_candidates"]},
            {"AGENTIC-575": "available", "IOSDOX-27458": "available"},
        )
        self.assertEqual(self.repository.sync_targets()["items"], [])


class ActiveWorkAuthConfigurationTests(unittest.TestCase):
    def test_manage_token_defaults_to_injected_home_and_explicit_file_overrides(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "service-home"
            default_file = (
                home / ".config" / "herdr-harness" / "active-work-manage-token"
            )
            default_file.parent.mkdir(parents=True)
            default_file.write_text(MANAGE_TOKEN + "\n", encoding="utf-8")
            default_file.chmod(0o600)

            self.assertEqual(
                _configured_manage_token({"HOME": str(home)}),
                MANAGE_TOKEN,
            )

            explicit_file = Path(temporary) / "explicit-manage-token"
            explicit_file.write_text("explicit-manage-token\n", encoding="utf-8")
            explicit_file.chmod(0o600)
            # An explicit file is authoritative and the default is not opened.
            default_file.chmod(0o644)
            self.assertEqual(
                _configured_manage_token(
                    {
                        "HOME": str(home),
                        "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(
                            explicit_file
                        ),
                    }
                ),
                "explicit-manage-token",
            )

    def test_unsafe_or_ambiguous_manage_token_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "service-home"
            default_file = (
                home / ".config" / "herdr-harness" / "active-work-manage-token"
            )
            default_file.parent.mkdir(parents=True)
            default_file.write_text(MANAGE_TOKEN, encoding="utf-8")
            default_file.chmod(0o644)

            with self.assertRaisesRegex(
                ActiveWorkAuthConfigurationError,
                "group or other",
            ):
                _configured_manage_token({"HOME": str(home)})

            explicit_file = Path(temporary) / "explicit-manage-token"
            explicit_file.write_text(MANAGE_TOKEN, encoding="utf-8")
            explicit_file.chmod(0o600)
            with self.assertRaisesRegex(
                ActiveWorkAuthConfigurationError,
                "either.*MANAGE_TOKEN.*MANAGE_TOKEN_FILE",
            ):
                _configured_manage_token(
                    {
                        "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": MANAGE_TOKEN,
                        "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(
                            explicit_file
                        ),
                    }
                )

    def test_inaccessible_default_manage_token_path_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "service-home"
            private_directory = home / ".config" / "herdr-harness"
            default_file = private_directory / "active-work-manage-token"
            private_directory.mkdir(parents=True)
            default_file.write_text(MANAGE_TOKEN, encoding="utf-8")
            default_file.chmod(0o600)
            private_directory.chmod(0o000)
            try:
                with self.assertRaisesRegex(
                    ActiveWorkAuthConfigurationError,
                    "cannot inspect the default Active Work management token file",
                ):
                    _configured_manage_token({"HOME": str(home)})
            finally:
                private_directory.chmod(0o700)

    def test_main_manage_and_ingest_tokens_must_be_distinct(self):
        collision_cases = (
            {
                "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": MAIN_TOKEN,
                "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": INGEST_TOKEN,
            },
            {
                "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": MANAGE_TOKEN,
                "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": MAIN_TOKEN,
            },
            {
                "HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN": MANAGE_TOKEN,
                "HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN": MANAGE_TOKEN,
            },
        )
        for environ in collision_cases:
            with self.subTest(environ=environ), self.assertRaisesRegex(
                ActiveWorkAuthConfigurationError,
                "distinct bearer tokens",
            ):
                make_handler(SimpleNamespace(environ=environ), api_token=MAIN_TOKEN)


class ActiveWorkHTTPIntegrationTests(ActiveWorkIntegrationFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.server = make_server(
            self.service,
            host="127.0.0.1",
            port=0,
            api_token=MAIN_TOKEN,
        )
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=1)
        super().tearDown()

    def request(
        self,
        path,
        *,
        method="GET",
        payload=None,
        token=MAIN_TOKEN,
        actor=None,
        base_url=None,
    ):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if actor is not None:
            headers["X-Herdr-Actor"] = actor
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            (base_url or self.base_url) + path,
            method=method,
            data=data,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            try:
                return exc.code, json.loads(exc.read())
            finally:
                exc.close()

    def test_manage_token_can_read_events_stream_but_ingest_token_cannot(self):
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_address[1],
            timeout=2,
        )
        self.addCleanup(connection.close)
        connection.request(
            "GET",
            "/api/v1/events?once=true",
            headers={"Authorization": f"Bearer {MANAGE_TOKEN}"},
        )
        response = connection.getresponse()
        payload = response.read().decode("utf-8")

        self.assertEqual(response.status, 200)
        self.assertIn("event: ready", payload)

        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_address[1],
            timeout=2,
        )
        self.addCleanup(connection.close)
        connection.request(
            "GET",
            "/api/v1/events?once=true",
            headers={"Authorization": f"Bearer {INGEST_TOKEN}"},
        )
        response = connection.getresponse()
        response.read()
        self.assertEqual(response.status, 401)

    def test_workflow_apply_route_creates_template_no_ops_on_replay_and_conflicts_on_changed_content(
        self,
    ):
        config = {
            "workflow": "integration-workflow",
            "version": 1,
            "title": "Integration workflow",
            "phases": [
                {"key": "plan", "title": "Plan"},
                {"key": "build", "title": "Build"},
            ],
            "stages": [
                {
                    "key": "plan",
                    "title": "Plan",
                    "phase": "plan",
                    "skill": "plan-skill",
                    "next": ["build"],
                },
                {
                    "key": "build",
                    "title": "Build",
                    "phase": "build",
                    "skill": "build-skill",
                    "next": [],
                },
            ],
        }
        create_status, created = self.request(
            "/api/v1/active-work/workflows",
            method="POST",
            token=MANAGE_TOKEN,
            payload=config,
        )
        list_status, listed = self.request(
            "/api/v1/active-work/workflows",
            token=MANAGE_TOKEN,
        )
        get_status, fetched = self.request(
            "/api/v1/active-work/workflows/integration-workflow",
            token=MANAGE_TOKEN,
        )
        replay_status, replayed = self.request(
            "/api/v1/active-work/workflows",
            method="POST",
            token=MANAGE_TOKEN,
            payload=config,
        )
        changed = copy.deepcopy(config)
        changed["stages"][1]["title"] = "Changed build"
        conflict_status, conflict = self.request(
            "/api/v1/active-work/workflows",
            method="POST",
            token=MANAGE_TOKEN,
            payload=changed,
        )
        invalid_status, invalid = self.request(
            "/api/v1/active-work/workflows",
            method="POST",
            token=MANAGE_TOKEN,
            payload={
                "workflow": "invalid-workflow",
                "version": 1,
                "title": "Invalid workflow",
                "phases": [{"key": "plan", "title": "Plan"}],
            },
        )

        self.assertEqual(create_status, 200)
        self.assertTrue(created["applied"])
        self.assertEqual(created["workflow"]["slug"], "integration-workflow")
        self.assertEqual(created["workflow"]["version"], 1)
        self.assertEqual(list_status, 200)
        matching = [
            workflow
            for workflow in listed["workflows"]
            if workflow["slug"] == "integration-workflow"
        ]
        self.assertEqual(matching[0]["stage_count"], 2)
        self.assertEqual(get_status, 200)
        self.assertIn("phases", fetched["workflow"])
        self.assertIn("stages", fetched["workflow"])
        self.assertIn("config", fetched["workflow"])
        self.assertEqual(replay_status, 200)
        self.assertFalse(replayed["applied"])
        self.assertEqual(replayed["reason"], "unchanged")
        self.assertEqual(conflict_status, 409)
        self.assertEqual(conflict["error"]["code"], "workflow_version_conflict")
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid["error"]["code"], "workflow_config_invalid")
        self.assertIn("stages", invalid["error"]["message"])

    def test_stage_patch_merges_documents_bumps_revision_and_emits_sse_stage_patched(self):
        create_status, created = self.request(
            "/api/v1/active-work/items",
            method="POST",
            token=MANAGE_TOKEN,
            payload={"kind": "task", "title": "Stage patch target"},
        )
        item_id = created["item"]["id"]
        before = self.broker.latest_id
        patch_status, patched = self.request(
            f"/api/v1/active-work/items/{item_id}/stages/plan",
            method="PATCH",
            token=MANAGE_TOKEN,
            payload={"content": {"documents": {"doc-1": {"title": "a"}}}},
        )
        unknown_status, unknown = self.request(
            f"/api/v1/active-work/items/{item_id}/stages/unknown-stage",
            method="PATCH",
            token=MANAGE_TOKEN,
            payload={"summary": "No such stage"},
        )

        self.assertEqual(create_status, 201)
        self.assertEqual(patch_status, 200)
        self.assertEqual(patched["item"]["revision"], created["item"]["revision"] + 1)
        plan = next(stage for stage in patched["item"]["stages"] if stage["stage_key"] == "plan")
        self.assertEqual(plan["content"]["documents"]["doc-1"], {"title": "a"})
        updates = [
            event
            for event in self.broker.after(before)
            if event["event"] == "active_work.updated"
        ]
        self.assertTrue(
            any(
                event["data"]["change"] == "stage_patched"
                and event["data"]["work_item_id"] == item_id
                for event in updates
            )
        )
        self.assertEqual(unknown_status, 404)
        self.assertEqual(unknown["error"]["code"], "active_work_stage_not_found")

    def test_explicit_jira_setup_is_idempotent_and_publishes_sse_update(self):
        before = self.broker.latest_id

        first_status, first = self.request(
            "/api/v1/active-work/jira/AGENTIC-575/setup",
            method="POST",
        )
        self.tools.issue["title"] = "Mobile API Impact Guard, refreshed"
        self.tools.issue["status"] = "In Code Review"
        second_status, second = self.request(
            "/api/v1/active-work/jira/AGENTIC-575/setup",
            method="POST",
        )

        self.assertEqual(first_status, 201)
        self.assertEqual(second_status, 200)
        self.assertTrue(first["created"])
        self.assertFalse(second["created"])
        self.assertEqual(first["item"]["id"], second["item"]["id"])
        self.assertEqual(second["item"]["jira_links"][0]["status"], "In Code Review")
        self.assertEqual(len(self.repository.board_projection()["items"]), 1)
        updates = [
            event
            for event in self.broker.after(before)
            if event["event"] == "active_work.updated"
        ]
        self.assertEqual(
            [event["data"]["change"] for event in updates],
            ["jira_setup", "jira_refreshed"],
        )
        self.assertTrue(
            all(event["data"]["work_item_id"] == first["item"]["id"] for event in updates)
        )
        audit = self.repository._database.execute(
            "SELECT actor FROM active_work_audit_events WHERE action = 'setup_jira'"
        ).fetchone()
        self.assertEqual(audit["actor"], "user")

    def test_manage_token_controls_only_active_work_and_records_agent_actor(self):
        create_status, created = self.request(
            "/api/v1/active-work/items",
            method="POST",
            token=MANAGE_TOKEN,
            actor="agent:ticket-curator",
            payload={"kind": "task", "title": "Managed by an agent"},
        )
        item_id = created["item"]["id"]
        detail_status, detail = self.request(
            f"/api/v1/active-work/items/{item_id}",
            token=MANAGE_TOKEN,
        )
        patch_status, patched = self.request(
            f"/api/v1/active-work/items/{item_id}",
            method="PATCH",
            token=MANAGE_TOKEN,
            actor="agent:ticket-curator",
            payload={
                "expected_revision": detail["item"]["revision"],
                "summary": "Updated through the least-privilege API.",
            },
        )
        transition_status, transitioned = self.request(
            f"/api/v1/active-work/items/{item_id}/transitions",
            method="POST",
            token=MANAGE_TOKEN,
            actor="agent:pipeline-manager",
            payload={
                "expected_revision": patched["item"]["revision"],
                "to_stage_key": "plan",
            },
        )
        targets_status, targets = self.request(
            "/api/v1/active-work/sync-targets",
            token=MANAGE_TOKEN,
        )
        ingest_status, ingested = self.request(
            "/api/v1/active-work/ingestions",
            method="POST",
            token=MANAGE_TOKEN,
            actor="agent:activity-observer",
            payload={
                "source": "agent-cli",
                "idempotency_key": "manage-token-observation-1",
                "observed_at": "2026-08-26T20:00:00Z",
                "selector": {"work_item_id": item_id},
                "item": {"next_action": "Review the generated plan."},
            },
        )
        board_status, _ = self.request(
            "/api/v1/active-work",
            token=MANAGE_TOKEN,
        )
        health_status, health_denied = self.request(
            "/api/v1/health",
            token=MANAGE_TOKEN,
        )
        workspaces_status, workspaces_denied = self.request(
            "/api/v1/workspaces",
            token=MANAGE_TOKEN,
        )

        self.assertEqual(
            [
                create_status,
                detail_status,
                patch_status,
                transition_status,
                targets_status,
                ingest_status,
                board_status,
            ],
            [201, 200, 200, 200, 200, 200, 200],
        )
        self.assertEqual(transitioned["item"]["current_stage_key"], "plan")
        self.assertEqual([item["work_item_id"] for item in targets["items"]], [item_id])
        self.assertTrue(ingested["applied"])
        self.assertEqual(health_status, 401)
        self.assertEqual(workspaces_status, 401)
        self.assertEqual(health_denied["error"]["code"], "unauthorized")
        self.assertEqual(workspaces_denied["error"]["code"], "unauthorized")

        audit = self.repository._database.execute(
            "SELECT action, actor FROM active_work_audit_events ORDER BY created_at"
        ).fetchall()
        self.assertEqual(
            [(row["action"], row["actor"]) for row in audit],
            [
                ("create_item", "agent:ticket-curator"),
                ("patch_item", "agent:ticket-curator"),
                ("transition", "agent:pipeline-manager"),
                ("ingest", "agent:activity-observer"),
            ],
        )

    def test_manage_token_has_safe_default_actor_and_rejects_spoofed_actor(self):
        setup_status, setup = self.request(
            "/api/v1/active-work/jira/AGENTIC-575/setup",
            method="POST",
            token=MANAGE_TOKEN,
        )
        invalid_status, invalid = self.request(
            "/api/v1/active-work/items",
            method="POST",
            token=MANAGE_TOKEN,
            actor="user",
            payload={"title": "Must not be created"},
        )

        self.assertEqual(setup_status, 201)
        self.assertTrue(setup["created"])
        self.assertEqual(invalid_status, 400)
        self.assertEqual(invalid["error"]["code"], "active_work_actor_invalid")
        audit = self.repository._database.execute(
            "SELECT actor FROM active_work_audit_events WHERE action = 'setup_jira'"
        ).fetchone()
        self.assertEqual(audit["actor"], "agent:active-work-cli")
        self.assertEqual(len(self.repository.board_projection()["items"]), 1)

    def test_scoped_tokens_do_not_lock_unrelated_routes_without_main_token(self):
        open_server = make_server(
            self.service,
            host="127.0.0.1",
            port=0,
            api_token="",
        )
        thread = threading.Thread(target=open_server.serve_forever, daemon=True)
        thread.start()
        base_url = f"http://127.0.0.1:{open_server.server_address[1]}"
        self.addCleanup(thread.join, 1)
        self.addCleanup(open_server.server_close)
        self.addCleanup(open_server.shutdown)

        health_status, _ = self.request(
            "/api/v1/health",
            token=None,
            base_url=base_url,
        )
        board_denied_status, _ = self.request(
            "/api/v1/active-work",
            token=None,
            base_url=base_url,
        )
        board_status, _ = self.request(
            "/api/v1/active-work",
            token=MANAGE_TOKEN,
            base_url=base_url,
        )
        targets_status, _ = self.request(
            "/api/v1/active-work/sync-targets",
            token=INGEST_TOKEN,
            base_url=base_url,
        )

        self.assertEqual(health_status, 200)
        self.assertEqual(board_denied_status, 401)
        self.assertEqual(board_status, 200)
        self.assertEqual(targets_status, 200)

    def test_options_advertises_active_work_actor_header(self):
        request = urllib.request.Request(
            self.base_url + "/api/v1/active-work",
            method="OPTIONS",
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            allowed = response.headers.get("Access-Control-Allow-Headers", "")
        self.assertIn("X-Herdr-Actor", allowed)

    def test_create_detail_patch_and_transition_routes_share_one_revisioned_item(self):
        create_status, created = self.request(
            "/api/v1/active-work/items",
            method="POST",
            payload={
                "kind": "feature",
                "title": "Agent-aware command board",
                "summary": "Initial product shape.",
            },
        )
        item_id = created["item"]["id"]
        detail_status, detail = self.request(f"/api/v1/active-work/items/{item_id}")
        patch_status, patched = self.request(
            f"/api/v1/active-work/items/{item_id}",
            method="PATCH",
            payload={
                "expected_revision": detail["item"]["revision"],
                "summary": "The board and Focus Route use the same durable item.",
                "next_action": "Approve the plan.",
            },
        )
        stale_status, stale = self.request(
            f"/api/v1/active-work/items/{item_id}",
            method="PATCH",
            payload={
                "expected_revision": detail["item"]["revision"],
                "summary": "A stale client must not win.",
            },
        )
        transition_status, transitioned = self.request(
            f"/api/v1/active-work/items/{item_id}/transitions",
            method="POST",
            payload={
                "expected_revision": patched["item"]["revision"],
                "to_stage_key": "plan",
                "attention": "human",
                "note": "Plan is ready for owner review.",
            },
        )
        board_status, board = self.request("/api/v1/active-work")

        self.assertEqual(
            [create_status, detail_status, patch_status, transition_status, board_status],
            [201, 200, 200, 200, 200],
        )
        self.assertEqual(stale_status, 409)
        self.assertEqual(stale["error"]["code"], "active_work_revision_conflict")
        self.assertEqual(transitioned["item"]["current_stage_key"], "plan")
        self.assertTrue(transitioned["item"]["needs_attention"])
        self.assertEqual(board["items"][0]["id"], item_id)
        self.assertEqual(
            board["items"][0]["summary"],
            "The board and Focus Route use the same durable item.",
        )

    def test_scoped_ingest_token_is_confined_to_sync_routes(self):
        create_status, created = self.request(
            "/api/v1/active-work/items",
            method="POST",
            payload={"kind": "task", "title": "Tracked sync target"},
        )
        item_id = created["item"]["id"]

        targets_status, targets = self.request(
            "/api/v1/active-work/sync-targets",
            token=INGEST_TOKEN,
        )
        ingest_status, ingested = self.request(
            "/api/v1/active-work/ingestions",
            method="POST",
            token=INGEST_TOKEN,
            actor="user",
            payload={
                "source": "buzz",
                "idempotency_key": "integration-observation-1",
                "observed_at": "2026-08-26T16:00:00Z",
                "selector": {"work_item_id": item_id},
                "item": {"summary": "Observed by the external Buzz sync agent."},
            },
        )
        wrong_source_status, wrong_source = self.request(
            "/api/v1/active-work/ingestions",
            method="POST",
            token=INGEST_TOKEN,
            payload={
                "source": "jira",
                "idempotency_key": "integration-wrong-source",
                "observed_at": "2026-08-26T16:01:00Z",
                "selector": {"work_item_id": item_id},
                "item": {"summary": "The scoped token must not write this."},
            },
        )
        board_denied_status, board_denied = self.request(
            "/api/v1/active-work",
            token=INGEST_TOKEN,
        )
        create_denied_status, create_denied = self.request(
            "/api/v1/active-work/items",
            method="POST",
            token=INGEST_TOKEN,
            payload={"title": "This must not be created"},
        )
        board_status, board = self.request("/api/v1/active-work")

        self.assertEqual(create_status, 201)
        self.assertEqual(targets_status, 200)
        self.assertEqual([item["work_item_id"] for item in targets["items"]], [item_id])
        self.assertEqual(ingest_status, 200)
        self.assertTrue(ingested["applied"])
        self.assertEqual(wrong_source_status, 403)
        self.assertEqual(
            wrong_source["error"]["code"],
            "active_work_ingest_scope_forbidden",
        )
        self.assertEqual(board_denied_status, 401)
        self.assertEqual(create_denied_status, 401)
        self.assertEqual(board_denied["error"]["code"], "unauthorized")
        self.assertEqual(create_denied["error"]["code"], "unauthorized")
        self.assertEqual(board_status, 200)
        self.assertEqual(board["items"][0]["summary"], "Observed by the external Buzz sync agent.")
        self.assertEqual(len(board["items"]), 1)
        audit = self.repository._database.execute(
            "SELECT actor FROM active_work_audit_events WHERE action = 'ingest' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        self.assertEqual(audit["actor"], "sync:buzz")


if __name__ == "__main__":
    unittest.main()
