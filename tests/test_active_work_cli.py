import io
import json
import tempfile
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts import herdr_active_work_cli as cli


DEFAULT_STAGE_KEYS = (
    "start-ticket",
    "plan",
    "implement",
    "architect-code-review",
    "proof",
    "code-review-pre-pr",
    "pr",
    "pr-triage",
)


def item(
    identifier="work_ticket_1",
    *,
    key="IOSDOX-27492",
    revision=3,
    title="Agent-aware board",
):
    return {
        "id": identifier,
        "kind": "task",
        "title": title,
        "summary": "",
        "lifecycle": "active",
        "current_stage_key": "plan",
        "next_action": "Approve the plan.",
        "revision": revision,
        "setup_state": "board_created",
        "needs_attention": True,
        "attention_reason": "Checkpoint pending at Plan",
        "updated_at": "2026-08-26T20:00:00.000Z",
        "jira_links": [{"issue_key": key, "site": "doximity.atlassian.net"}],
    }


def board(*, items=None, candidates=None):
    return {
        "ok": True,
        "pipeline": {
            "id": "pipeline_buzz_feature_work_v1",
            "stages": [{"stage_key": stage} for stage in DEFAULT_STAGE_KEYS],
        },
        "items": list(items or []),
        "jira_candidates": list(candidates or []),
        "jira_candidates_status": {"ok": True, "error": None},
    }


class FakeResponse:
    def __init__(self, payload, *, status=200, final_url=None):
        self.status = status
        self._raw = (
            payload
            if isinstance(payload, bytes)
            else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        )
        self._final_url = final_url
        self._request_url = ""

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, traceback):
        return False

    def read(self, maximum=-1):
        if maximum is None or maximum < 0:
            return self._raw
        return self._raw[:maximum]

    def geturl(self):
        return self._final_url or self._request_url


class RecordingOpener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def __call__(self, request, *, timeout):
        self.requests.append(
            {
                "method": request.get_method(),
                "url": request.full_url,
                "headers": {key.lower(): value for key, value in request.header_items()},
                "body": request.data,
                "timeout": timeout,
            }
        )
        if not self.responses:
            raise AssertionError("unexpected HTTP request")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        response._request_url = request.full_url
        return response


class ActiveWorkCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.token_path = Path(self.temporary.name) / "active-work-manage-token"
        self.token_path.write_text("manage-token-123\n", encoding="utf-8")
        self.token_path.chmod(0o600)
        self.environ = {
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(self.token_path),
            "HERDR_ACTIVE_WORK_ACTOR": "agent:test-runner",
        }

    def run_cli(self, argv, *responses, stdin="", environ=None):
        output = io.StringIO()
        error = io.StringIO()
        opener = RecordingOpener(*responses)
        status = cli.main(
            argv,
            environ=self.environ if environ is None else environ,
            stdin=io.StringIO(stdin),
            stdout=output,
            stderr=error,
            open_url=opener,
        )
        stdout_value = json.loads(output.getvalue()) if output.getvalue() else None
        stderr_value = json.loads(error.getvalue()) if error.getvalue() else None
        return status, stdout_value, stderr_value, opener

    def test_candidates_is_read_only_and_filters_already_connected_items(self):
        candidates = [
            {"key": "IOSDOX-27492", "title": "Ready", "setup_state": "available"},
            {"key": "AGENTIC-575", "title": "Tracked", "setup_state": "board_created"},
        ]
        status, output, error, opener = self.run_cli(
            ["candidates"],
            FakeResponse(board(candidates=candidates)),
        )

        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["api_version"], cli.API_VERSION)
        self.assertEqual(output["command"], "candidates")
        self.assertEqual(output["data"]["count"], 1)
        self.assertEqual(output["data"]["items"][0]["key"], "IOSDOX-27492")
        self.assertEqual(opener.requests[0]["method"], "GET")
        self.assertIsNone(opener.requests[0]["body"])
        self.assertEqual(opener.requests[0]["headers"]["authorization"], "Bearer manage-token-123")
        self.assertEqual(opener.requests[0]["headers"]["x-herdr-actor"], "agent:test-runner")

    def test_candidates_all_preserves_connected_candidates(self):
        candidates = [
            {"key": "IOSDOX-27492", "setup_state": "available"},
            {"key": "AGENTIC-575", "setup_state": "ready"},
        ]
        status, output, _, _ = self.run_cli(
            ["candidates", "--all"],
            FakeResponse(board(candidates=candidates)),
        )
        self.assertEqual(status, 0)
        self.assertEqual(output["data"]["count"], 2)

    def test_candidates_fails_closed_when_jira_candidates_are_unavailable(self):
        unavailable = board()
        unavailable["jira_candidates_status"] = {
            "ok": False,
            "error": "acli timed out while listing assigned tickets",
        }
        status, output, error, opener = self.run_cli(
            ["candidates"],
            FakeResponse(unavailable),
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "jira_candidates_unavailable")
        self.assertTrue(error["error"]["retryable"])
        self.assertEqual(len(opener.requests), 1)

    def test_list_defaults_to_slim_items_and_full_returns_board(self):
        projection = board(items=[item()])
        status, output, _, _ = self.run_cli(["list"], FakeResponse(projection))
        self.assertEqual(status, 0)
        self.assertEqual(output["data"]["items"][0]["jira_keys"], ["IOSDOX-27492"])
        self.assertNotIn("jira_links", output["data"]["items"][0])

        status, output, _, _ = self.run_cli(["list", "--full"], FakeResponse(projection))
        self.assertEqual(status, 0)
        self.assertEqual(output["data"]["board"], projection)

    def test_show_resolves_a_connected_jira_key_then_fetches_detail(self):
        detail = item(revision=8)
        status, output, error, opener = self.run_cli(
            ["show", "iosdox-27492"],
            FakeResponse(board(items=[item()])),
            FakeResponse({"ok": True, "item": detail}),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["data"]["item"]["revision"], 8)
        self.assertEqual(
            [request["url"] for request in opener.requests],
            [
                "http://127.0.0.1:9092/api/v1/active-work",
                "http://127.0.0.1:9092/api/v1/active-work/items/work_ticket_1",
            ],
        )

    def test_show_unconnected_jira_key_has_structured_not_found_error(self):
        status, output, error, opener = self.run_cli(
            ["show", "IOSDOX-27492"],
            FakeResponse(board()),
        )
        self.assertEqual(status, 4)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "active_work_not_connected")
        self.assertEqual(error["error"]["http_status"], 404)
        self.assertEqual(len(opener.requests), 1)

    def test_connect_is_singular_bodyless_and_idempotent(self):
        connected = item()
        first_status, first, _, first_opener = self.run_cli(
            ["connect", "iosdox-27492"],
            FakeResponse({"ok": True, "created": True, "item": connected}, status=201),
        )
        second_status, second, _, second_opener = self.run_cli(
            ["connect", "IOSDOX-27492"],
            FakeResponse({"ok": True, "created": False, "item": connected}),
        )

        self.assertEqual([first_status, second_status], [0, 0])
        self.assertEqual(first["data"]["outcome"], "created")
        self.assertEqual(second["data"]["outcome"], "refreshed")
        for opener in (first_opener, second_opener):
            self.assertEqual(opener.requests[0]["method"], "POST")
            self.assertEqual(
                opener.requests[0]["url"],
                "http://127.0.0.1:9092/api/v1/active-work/jira/IOSDOX-27492/setup",
            )
            self.assertIsNone(opener.requests[0]["body"])

    def test_connect_rejects_a_second_ticket_before_network(self):
        status, output, error, opener = self.run_cli(
            ["connect", "IOSDOX-27492", "AGENTIC-575"],
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_arguments")
        self.assertEqual(opener.requests, [])

    def test_connect_rejects_a_missing_created_outcome(self):
        status, output, error, opener = self.run_cli(
            ["connect", "IOSDOX-27492"],
            FakeResponse({"ok": True, "item": item()}),
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_response")
        self.assertEqual(len(opener.requests), 1)

    def test_create_sends_only_explicit_fields_and_structured_metadata(self):
        created = item(identifier="work_feature_1", key="")
        status, output, error, opener = self.run_cli(
            [
                "create",
                "--kind",
                "feature",
                "--title",
                "Agent command surface",
                "--summary",
                "Production CLI",
                "--metadata-json",
                '{"owner":"platform"}',
            ],
            FakeResponse({"ok": True, "item": created}, status=201),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["data"]["item"]["id"], "work_feature_1")
        payload = json.loads(opener.requests[0]["body"])
        self.assertEqual(
            payload,
            {
                "kind": "feature",
                "metadata": {"owner": "platform"},
                "summary": "Production CLI",
                "title": "Agent command surface",
            },
        )

    def test_workflow_apply_posts_validated_config_and_validate_flag_skips_network(self):
        config = {
            "workflow": "test-workflow",
            "version": 1,
            "title": "Test workflow",
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
        path = Path(self.temporary.name) / "workflow.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        status, output, error, opener = self.run_cli(
            ["workflow-apply", "--file", str(path)],
            FakeResponse(
                {
                    "ok": True,
                    "applied": True,
                    "reason": None,
                    "workflow": {"slug": "test-workflow", "version": 1},
                }
            ),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertTrue(output["data"]["applied"])
        self.assertEqual(opener.requests[0]["method"], "POST")
        self.assertEqual(json.loads(opener.requests[0]["body"]), config)

        status, output, error, opener = self.run_cli(
            ["workflow-apply", "--file", str(path), "--validate"]
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertTrue(output["data"]["valid"])
        self.assertEqual(opener.requests, [])

        invalid = json.loads(json.dumps(config))
        invalid["stages"][0]["next"] = ["plan"]
        path.write_text(json.dumps(invalid), encoding="utf-8")
        status, output, error, opener = self.run_cli(
            ["workflow-apply", "--file", str(path), "--validate"]
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "workflow_config_invalid")
        self.assertEqual(opener.requests, [])

    def test_attach_doc_builds_documents_patch_payload(self):
        arguments = [
            "attach-doc",
            "work_ticket_1",
            "--stage",
            "plan",
            "--id",
            "plan-approval",
            "--title",
            "plan-approval.html",
            "--kind",
            "html",
            "--skill",
            "buzz-plan",
            "--status",
            "approved",
            "--by",
            "Ronnie",
            "--url",
            "https://example.test/tickets/AGENTIC-575/plan-approval.html",
        ]
        status, output, error, opener = self.run_cli(
            arguments,
            FakeResponse({"ok": True, "item": item()}),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["data"]["item"]["id"], "work_ticket_1")
        request = opener.requests[0]
        self.assertEqual(request["method"], "PATCH")
        self.assertEqual(
            request["url"],
            "http://127.0.0.1:9092/api/v1/active-work/items/work_ticket_1/stages/plan",
        )
        document = json.loads(request["body"])["content"]["documents"]["plan-approval"]
        self.assertEqual(
            {key: value for key, value in document.items() if key != "at"},
            {
                "title": "plan-approval.html",
                "kind": "html",
                "skill": "buzz-plan",
                "status": "approved",
                "by": "Ronnie",
                "url": "https://example.test/tickets/AGENTIC-575/plan-approval.html",
            },
        )
        self.assertRegex(document["at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

        status, _, error, opener = self.run_cli(
            [*arguments, "--at", "2026-08-26T20:00:00Z"],
            FakeResponse({"ok": True, "item": item()}),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        body = json.loads(opener.requests[0]["body"])
        self.assertEqual(
            body["content"]["documents"]["plan-approval"]["at"],
            "2026-08-26T20:00:00Z",
        )

    def test_update_fetches_revision_once_and_never_retries(self):
        updated = item(revision=4, title="Revised title")
        status, output, error, opener = self.run_cli(
            ["update", "work_ticket_1", "--title", "Revised title"],
            FakeResponse({"ok": True, "item": item(revision=3)}),
            FakeResponse({"ok": True, "item": updated}),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["data"]["item"]["revision"], 4)
        self.assertEqual(len(opener.requests), 2)
        self.assertEqual(opener.requests[1]["method"], "PATCH")
        self.assertEqual(
            json.loads(opener.requests[1]["body"]),
            {"expected_revision": 3, "title": "Revised title"},
        )

    def test_update_requires_a_field_before_fetching_revision(self):
        status, output, error, opener = self.run_cli(["update", "work_ticket_1"])
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_arguments")
        self.assertEqual(opener.requests, [])

    def test_move_with_explicit_revision_does_not_fetch_and_maps_stage_fields(self):
        moved = item(revision=10)
        status, output, error, opener = self.run_cli(
            [
                "move",
                "work_ticket_1",
                "--to",
                "implement",
                "--attention",
                "agent",
                "--note",
                "Plan approved.",
                "--expected-revision",
                "9",
            ],
            FakeResponse({"ok": True, "item": moved}),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertEqual(output["data"]["item"]["revision"], 10)
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(
            json.loads(opener.requests[0]["body"]),
            {
                "attention": "agent",
                "expected_revision": 9,
                "note": "Plan approved.",
                "to_stage_key": "implement",
            },
        )

    def test_revision_conflict_is_preserved_and_not_retried(self):
        body = json.dumps(
            {
                "ok": False,
                "error": {
                    "code": "active_work_revision_conflict",
                    "message": "Work item was changed by another client",
                },
            }
        ).encode("utf-8")
        conflict = urllib.error.HTTPError(
            "http://127.0.0.1:9092/api/v1/active-work/items/work_ticket_1",
            409,
            "Conflict",
            {},
            io.BytesIO(body),
        )
        status, output, error, opener = self.run_cli(
            [
                "update",
                "work_ticket_1",
                "--summary",
                "stale",
                "--expected-revision",
                "2",
            ],
            conflict,
        )
        self.assertEqual(status, 5)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "active_work_revision_conflict")
        self.assertEqual(error["error"]["http_status"], 409)
        self.assertFalse(error["error"]["retryable"])
        self.assertEqual(len(opener.requests), 1)
        self.assertTrue(conflict.fp is None or conflict.fp.closed)

    def test_observe_reads_stdin_and_reports_an_idempotent_replay(self):
        observation = {
            "source": "agent-sync",
            "idempotency_key": "observation-1",
            "observed_at": "2026-08-26T20:00:00Z",
            "selector": {"jira_key": "IOSDOX-27492"},
            "current_stage_key": "implement",
        }
        status, output, error, opener = self.run_cli(
            ["observe", "--file", "-"],
            FakeResponse(
                {
                    "ok": True,
                    "applied": False,
                    "replayed": True,
                    "stale": False,
                    "receipt_id": "ingest_1",
                    "item": item(),
                }
            ),
            stdin=json.dumps(observation),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertTrue(output["data"]["replayed"])
        self.assertFalse(output["data"]["applied"])
        self.assertEqual(opener.requests[0]["method"], "POST")
        self.assertEqual(
            opener.requests[0]["url"],
            "http://127.0.0.1:9092/api/v1/active-work/ingestions",
        )
        self.assertEqual(json.loads(opener.requests[0]["body"]), observation)

    def test_observe_rejects_missing_idempotency_before_network(self):
        status, output, error, opener = self.run_cli(
            ["observe", "--file", "-"],
            stdin=json.dumps(
                {
                    "source": "agent-sync",
                    "observed_at": "2026-08-26T20:00:00Z",
                    "selector": {"work_item_id": "work_ticket_1"},
                }
            ),
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_payload")
        self.assertEqual(opener.requests, [])

    def test_observe_rejects_an_incomplete_or_coerced_server_outcome(self):
        observation = json.dumps(
            {
                "source": "agent-sync",
                "idempotency_key": "observation-contract",
                "observed_at": "2026-08-26T20:00:00Z",
                "selector": {"work_item_id": "work_ticket_1"},
            }
        )
        invalid_responses = (
            {"ok": True},
            {
                "ok": True,
                "applied": "false",
                "replayed": False,
                "stale": False,
                "receipt_id": "ingest_1",
                "item": item(),
            },
        )
        for response in invalid_responses:
            with self.subTest(response=response):
                status, output, error, opener = self.run_cli(
                    ["observe", "--file", "-"],
                    FakeResponse(response),
                    stdin=observation,
                )
                self.assertEqual(status, 3)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "invalid_response")
                self.assertEqual(len(opener.requests), 1)

    def test_plain_http_is_restricted_to_loopback(self):
        status, output, error, opener = self.run_cli(
            ["--base-url", "http://work-mac.tailnet.example", "list"],
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_configuration")
        self.assertEqual(opener.requests, [])

    def test_base_url_rejects_an_arbitrary_path_before_network(self):
        status, output, error, opener = self.run_cli(
            ["--base-url", "https://work-mac.example.test/herdr", "list"],
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_configuration")
        self.assertEqual(opener.requests, [])

    def test_default_http_opener_explicitly_disables_environment_proxies(self):
        with patch.object(
            cli.urllib.request,
            "build_opener",
            wraps=urllib.request.build_opener,
        ) as builder:
            cli.ActiveWorkClient(
                cli.DEFAULT_BASE_URL,
                token="safe-token",
                actor="agent:test",
                timeout=2,
            )
        handlers = builder.call_args.args
        proxy_handlers = [handler for handler in handlers if isinstance(handler, urllib.request.ProxyHandler)]
        self.assertEqual(len(proxy_handlers), 1)
        self.assertEqual(proxy_handlers[0].proxies, {})

    def test_redirect_is_rejected_without_a_second_request(self):
        response = FakeResponse(
            {"ok": True},
            final_url="https://attacker.example.test/api/v1/active-work",
        )
        status, output, error, opener = self.run_cli(["list"], response)
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "redirect_not_allowed")
        self.assertEqual(len(opener.requests), 1)

    def test_manage_token_file_rejects_group_permissions_and_symlinks(self):
        self.token_path.chmod(0o640)
        status, _, error, opener = self.run_cli(["list"])
        self.assertEqual(status, 3)
        self.assertEqual(error["error"]["code"], "manage_token_unsafe")
        self.assertEqual(opener.requests, [])

    def test_manage_token_must_be_printable_ascii_without_del(self):
        for token in ("unicode-\u2603", "contains\x7fdel", "contains space"):
            with self.subTest(token=repr(token)):
                environment = {"HERDR_ACTIVE_WORK_MANAGE_TOKEN": token}
                status, output, error, opener = self.run_cli(["list"], environ=environment)
                self.assertEqual(status, 2)
                self.assertIsNone(output)
                self.assertEqual(error["error"]["code"], "invalid_configuration")
                self.assertEqual(opener.requests, [])

        self.token_path.chmod(0o600)
        link = Path(self.temporary.name) / "token-link"
        link.symlink_to(self.token_path)
        environment = {"HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(link)}
        status, _, error, opener = self.run_cli(["list"], environ=environment)
        self.assertEqual(status, 3)
        self.assertEqual(error["error"]["code"], "manage_token_unsafe")
        self.assertEqual(opener.requests, [])

    def test_token_file_and_direct_token_are_mutually_exclusive(self):
        environment = {
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(self.token_path),
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN": "other-token",
        }
        status, output, error, opener = self.run_cli(["list"], environ=environment)
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_configuration")
        self.assertEqual(opener.requests, [])

    def test_raw_token_option_is_neither_abbreviated_nor_reflected(self):
        accidental_secret = "SUPERSECRET-DO-NOT-LOG"
        status, output, error, opener = self.run_cli(
            ["--token", accidental_secret, "list"],
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_arguments")
        self.assertNotIn(accidental_secret, json.dumps(error))
        self.assertEqual(opener.requests, [])

    def test_invalid_actor_is_rejected_before_network(self):
        environment = {
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(self.token_path),
            "HERDR_ACTIVE_WORK_ACTOR": "user:spoofed",
        }
        status, _, error, opener = self.run_cli(["list"], environ=environment)
        self.assertEqual(status, 2)
        self.assertEqual(error["error"]["code"], "invalid_actor")
        self.assertEqual(opener.requests, [])

    def test_http_auth_error_preserves_backend_code(self):
        body = json.dumps(
            {
                "ok": False,
                "error": {
                    "code": "unauthorized",
                    "message": "A valid bearer token is required",
                },
            }
        ).encode("utf-8")
        unauthorized = urllib.error.HTTPError(
            "http://127.0.0.1:9092/api/v1/active-work",
            401,
            "Unauthorized",
            {},
            io.BytesIO(body),
        )
        status, output, error, opener = self.run_cli(["list"], unauthorized)
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "unauthorized")
        self.assertEqual(error["error"]["http_status"], 401)
        self.assertEqual(len(opener.requests), 1)

    def test_loaded_token_is_redacted_from_http_and_transport_errors(self):
        reflected = json.dumps(
            {
                "ok": False,
                "error": {
                    "code": "server_error",
                    "message": "credential manage-token-123 was rejected",
                },
            }
        ).encode("utf-8")
        server_error = urllib.error.HTTPError(
            "http://127.0.0.1:9092/api/v1/active-work",
            500,
            "Error",
            {},
            io.BytesIO(reflected),
        )
        status, _, error, _ = self.run_cli(["list"], server_error)
        self.assertEqual(status, 3)
        self.assertNotIn("manage-token-123", json.dumps(error))
        self.assertIn("[REDACTED]", error["error"]["message"])

    def test_server_error_code_is_validated_and_cannot_reflect_the_token(self):
        reflected = json.dumps(
            {
                "ok": False,
                "error": {
                    "code": "manage-token-123",
                    "message": "failed",
                },
            }
        ).encode("utf-8")
        server_error = urllib.error.HTTPError(
            "http://127.0.0.1:9092/api/v1/active-work",
            500,
            "Error",
            {},
            io.BytesIO(reflected),
        )
        status, _, error, _ = self.run_cli(["list"], server_error)
        self.assertEqual(status, 3)
        self.assertEqual(error["error"]["code"], "herdr_http_error")
        self.assertNotIn("manage-token-123", json.dumps(error))

        transport_error = urllib.error.URLError("dial manage-token-123 failed")
        status, _, error, _ = self.run_cli(["list"], transport_error)
        self.assertEqual(status, 3)
        self.assertNotIn("manage-token-123", json.dumps(error))
        self.assertIn("[REDACTED]", error["error"]["message"])

    def test_loaded_token_is_redacted_from_successful_server_json(self):
        projection = board()
        projection["jira_candidates_status"] = {
            "ok": False,
            "error": "diagnostic contained manage-token-123",
        }
        status, output, error, _ = self.run_cli(["list"], FakeResponse(projection))
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertNotIn("manage-token-123", json.dumps(output))
        self.assertIn("[REDACTED]", output["data"]["jira_candidates_status"]["error"])

    def test_missing_ok_true_is_an_invalid_response_not_an_empty_board(self):
        status, output, error, opener = self.run_cli(["candidates"], FakeResponse({}))
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_response")
        self.assertEqual(len(opener.requests), 1)

    def test_ok_true_without_board_fields_is_not_treated_as_empty(self):
        status, output, error, opener = self.run_cli(
            ["candidates"],
            FakeResponse({"ok": True}),
        )
        self.assertEqual(status, 3)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_response")
        self.assertEqual(len(opener.requests), 1)

    def test_invalid_timeout_environment_uses_json_parse_error_contract(self):
        environment = {
            "HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE": str(self.token_path),
            "HERDR_ACTIVE_WORK_TIMEOUT": "not-a-number",
        }
        status, output, error, opener = self.run_cli(["list"], environ=environment)
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "invalid_arguments")
        self.assertEqual(opener.requests, [])

    def test_observation_file_uses_a_bounded_full_read(self):
        observation = {
            "source": "agent-sync",
            "idempotency_key": "large-observation",
            "observed_at": "2026-08-26T20:00:00Z",
            "selector": {"work_item_id": "work_ticket_1"},
            "item": {"metadata": {"note": "x" * 128_000}},
        }
        path = Path(self.temporary.name) / "observation.json"
        path.write_text(json.dumps(observation), encoding="utf-8")
        status, output, error, opener = self.run_cli(
            ["observe", "--file", str(path)],
            FakeResponse(
                {
                    "ok": True,
                    "applied": True,
                    "replayed": False,
                    "stale": False,
                    "receipt_id": "ingest_large",
                    "item": item(),
                }
            ),
        )
        self.assertEqual(status, 0)
        self.assertIsNone(error)
        self.assertTrue(output["data"]["applied"])
        self.assertEqual(json.loads(opener.requests[0]["body"]), observation)

    def test_oversized_request_has_json_error_instead_of_a_traceback(self):
        status, output, error, opener = self.run_cli(
            ["create", "--title", "large", "--summary", "x" * cli.MAX_REQUEST_BYTES],
        )
        self.assertEqual(status, 2)
        self.assertIsNone(output)
        self.assertEqual(error["error"]["code"], "request_too_large")
        self.assertEqual(opener.requests, [])

    def test_version_is_available_without_credentials(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(SystemExit) as context:
            cli._parser({}).parse_args(["--version"])
        self.assertEqual(context.exception.code, 0)
        self.assertEqual(output.getvalue().strip(), "herdr-active-work 2")


if __name__ == "__main__":
    unittest.main()
