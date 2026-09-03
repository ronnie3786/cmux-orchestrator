import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from herdr_harness.events import EventBroker
from herdr_harness.result_artifacts import ResultArtifactError, ResultArtifactStore
from herdr_harness.server import make_server
from herdr_harness.service import HerdrService


class ResultArtifactStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "private-artifacts"
        self.store = ResultArtifactStore(self.root, environ={})

    def write_source(self, name: str, data: bytes) -> Path:
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_file_registration_copies_privately_and_never_exposes_source_path(self):
        source = self.write_source("exports/Launch Notes.md", b"# Ready\n")

        artifact = self.store.create(
            origin_type="pane",
            origin_id="w1:p4",
            session_id="session-42",
            kind="file",
            location=str(source),
            title="Launch notes",
        )
        source.write_bytes(b"changed after registration")
        source.unlink()

        self.assertRegex(artifact["id"], r"^art_[0-9a-f]{24}$")
        self.assertEqual(artifact["originType"], "pane")
        self.assertEqual(artifact["originId"], "w1:p4")
        self.assertEqual(artifact["sessionId"], "session-42")
        self.assertEqual(artifact["title"], "Launch notes")
        self.assertEqual(artifact["filename"], "Launch Notes.md")
        self.assertEqual(artifact["contentType"], "text/markdown")
        self.assertEqual(artifact["byteSize"], 8)
        self.assertEqual(
            artifact["downloadPath"],
            f"/api/v1/result-artifacts/{artifact['id']}/content",
        )
        self.assertNotIn("url", artifact)
        self.assertNotIn("location", artifact)
        self.assertNotIn("path", artifact)

        with self.store.open_content(artifact["id"]) as content:
            self.assertEqual(content.handle.read(), b"# Ready\n")

        persisted = self.store.index_path.read_text(encoding="utf-8")
        self.assertNotIn(str(source), persisted)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.index_path.stat().st_mode & 0o777, 0o600)
        blobs = list(self.store.files_root.iterdir())
        self.assertEqual(len(blobs), 1)
        self.assertEqual(blobs[0].stat().st_mode & 0o777, 0o600)

    def test_link_registration_normalizes_http_url_and_omits_download_path(self):
        artifact = self.store.create(
            origin_type="agent_run",
            origin_id="agr_0123456789ab",
            kind="link",
            location="HTTPS://Example.COM:443/reports/final?mode=full#summary",
        )

        self.assertEqual(artifact["kind"], "link")
        self.assertEqual(artifact["title"], "final")
        self.assertEqual(artifact["url"], "https://example.com:443/reports/final?mode=full#summary")
        self.assertIsNone(artifact["sessionId"])
        self.assertIsNone(artifact["filename"])
        self.assertIsNone(artifact["contentType"])
        self.assertIsNone(artifact["byteSize"])
        self.assertNotIn("downloadPath", artifact)

        for invalid in (
            "file:///private/tmp/report.pdf",
            "javascript:alert(1)",
            "https://user:secret@example.com/private",
            "https:///missing-host",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ResultArtifactError):
                self.store.create(
                    origin_type="pane",
                    origin_id="w1:p1",
                    kind="link",
                    location=invalid,
                )

    def test_idempotent_retry_returns_original_without_copying_or_exposing_key(self):
        source = self.write_source("exports/retry.pdf", b"%PDF-stable")
        request = {
            "origin_type": "agent_run",
            "origin_id": "agr_retry",
            "session_id": "session-retry",
            "kind": "file",
            "location": str(source),
            "title": "Stable result",
            "idempotency_key": "pr_" + "a" * 64,
        }

        first, first_created = self.store.create_with_status(**request)
        source.unlink()
        second, second_created = self.store.create_with_status(**request)

        self.assertTrue(first_created)
        self.assertFalse(second_created)
        self.assertEqual(second, first)
        self.assertEqual(self.store.list(), [first])
        self.assertEqual(len(list(self.store.files_root.iterdir())), 1)
        self.assertNotIn("idempotencyKey", first)
        self.assertNotIn("requestFingerprint", first)

    def test_idempotency_key_reuse_with_different_request_conflicts(self):
        request = {
            "origin_type": "pane",
            "origin_id": "w1:p1",
            "kind": "link",
            "location": "https://example.com/first",
            "idempotency_key": "pr_collision",
        }
        self.store.create(**request)

        request["location"] = "https://example.com/second"
        with self.assertRaises(ResultArtifactError) as context:
            self.store.create(**request)

        self.assertEqual(context.exception.status, 409)
        self.assertEqual(
            context.exception.code,
            "result_artifact_idempotency_conflict",
        )
        self.assertEqual(len(self.store.list()), 1)

    def test_file_registration_rejects_traversal_symlinks_non_files_and_executables(self):
        source = self.write_source("safe/report.pdf", b"%PDF-test")
        traversing = str(self.base / "safe" / ".." / "safe" / "report.pdf")
        with self.assertRaisesRegex(ResultArtifactError, "traversal"):
            self.store.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=traversing,
            )

        symlink = self.base / "report-link.pdf"
        try:
            symlink.symlink_to(source)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        with self.assertRaisesRegex(ResultArtifactError, "symbolic link"):
            self.store.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=str(symlink),
            )

        directory = self.base / "folder.pdf"
        directory.mkdir()
        with self.assertRaisesRegex(ResultArtifactError, "regular file"):
            self.store.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=str(directory),
            )

        executable = self.write_source("renamed.pdf", b"#!/bin/sh\necho unsafe\n")
        with self.assertRaises(ResultArtifactError) as context:
            self.store.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=str(executable),
            )
        self.assertEqual(context.exception.status, 415)

    def test_file_registration_enforces_type_and_size_allowlists(self):
        unsupported = self.write_source("payload.command", b"echo no")
        with self.assertRaises(ResultArtifactError) as context:
            self.store.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=str(unsupported),
            )
        self.assertEqual(context.exception.code, "result_artifact_type_unsupported")

        bounded = ResultArtifactStore(
            self.base / "bounded",
            environ={"HERDR_HARNESS_RESULT_ARTIFACT_MAX_FILE_BYTES": "4"},
        )
        too_large = self.write_source("large.txt", b"12345")
        with self.assertRaises(ResultArtifactError) as context:
            bounded.create(
                origin_type="pane",
                origin_id="w1:p1",
                kind="file",
                location=str(too_large),
            )
        self.assertEqual(context.exception.status, 413)

    def test_concurrent_file_registrations_serialize_private_copies_and_stay_bounded(self):
        store = ResultArtifactStore(
            self.base / "concurrent",
            environ={
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_FILE_BYTES": "8",
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_TOTAL_BYTES": "8",
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_COUNT": "2",
            },
        )
        sources = [
            self.write_source(f"parallel/result-{index}.txt", b"data")
            for index in range(4)
        ]
        original_copy = store._copy_file
        original_write_blob_chunk = store._write_blob_chunk
        observation_lock = threading.Lock()
        start = threading.Barrier(len(sources) + 1)
        pause = threading.Event()
        active_copies = 0
        peak_copies = 0
        peak_managed_bytes = 0
        failures = []

        def observed_copy(location, artifact_id, records):
            nonlocal active_copies, peak_copies
            with observation_lock:
                active_copies += 1
                peak_copies = max(peak_copies, active_copies)
            try:
                pause.wait(0.04)
                return original_copy(location, artifact_id, records)
            finally:
                with observation_lock:
                    active_copies -= 1

        def observed_write_blob_chunk(descriptor, chunk):
            nonlocal peak_managed_bytes
            original_write_blob_chunk(descriptor, chunk)
            managed_bytes = sum(
                item.stat().st_size
                for item in store.files_root.iterdir()
                if item.name.endswith(".blob") or item.name.endswith(".tmp")
            )
            with observation_lock:
                peak_managed_bytes = max(peak_managed_bytes, managed_bytes)

        store._copy_file = observed_copy
        store._write_blob_chunk = observed_write_blob_chunk

        def register(index):
            start.wait()
            try:
                store.create(
                    origin_type="pane",
                    origin_id=f"w1:p{index}",
                    kind="file",
                    location=str(sources[index]),
                )
            except Exception as exc:  # pragma: no cover - asserted below
                failures.append(exc)

        threads = [
            threading.Thread(target=register, args=(index,))
            for index in range(len(sources))
        ]
        for thread in threads:
            thread.start()
        start.wait()
        for thread in threads:
            thread.join(timeout=2)

        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(failures, [])
        self.assertEqual(peak_copies, 1)
        self.assertEqual(peak_managed_bytes, 8)
        self.assertLessEqual(len(store.list()), 2)
        blobs = [
            item
            for item in store.files_root.iterdir()
            if item.name.endswith(".blob")
        ]
        self.assertLessEqual(len(blobs), 2)
        self.assertLessEqual(sum(item.stat().st_size for item in blobs), 8)
        self.assertFalse(any(item.name.endswith(".tmp") for item in store.files_root.iterdir()))

    def test_source_growth_never_writes_beyond_reserved_capacity(self):
        store = ResultArtifactStore(
            self.base / "growth-reservation",
            environ={
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_FILE_BYTES": "4",
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_TOTAL_BYTES": "4",
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_COUNT": "1",
            },
        )
        previous = self.write_source("growth/previous.txt", b"prev")
        store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="file",
            location=str(previous),
        )
        growing = self.write_source("growth/growing.txt", b"next")
        original_reserve = store._reserve_file_capacity_locked
        original_write_blob_chunk = store._write_blob_chunk
        peak_managed_bytes = 0

        def reserve_then_grow(records, *, required_bytes):
            retained = original_reserve(
                records,
                required_bytes=required_bytes,
            )
            with growing.open("ab") as handle:
                handle.write(b"grew")
            return retained

        def observed_write_blob_chunk(descriptor, chunk):
            nonlocal peak_managed_bytes
            original_write_blob_chunk(descriptor, chunk)
            peak_managed_bytes = max(
                peak_managed_bytes,
                sum(
                    item.stat().st_size
                    for item in store.files_root.iterdir()
                    if item.name.endswith(".blob") or item.name.endswith(".tmp")
                ),
            )

        store._reserve_file_capacity_locked = reserve_then_grow
        store._write_blob_chunk = observed_write_blob_chunk

        with self.assertRaises(ResultArtifactError) as context:
            store.create(
                origin_type="pane",
                origin_id="w1:p2",
                kind="file",
                location=str(growing),
            )

        self.assertEqual(context.exception.code, "result_artifact_source_changed")
        self.assertEqual(peak_managed_bytes, 4)
        self.assertEqual(store.list(), [])
        self.assertFalse(any(store.files_root.iterdir()))

    def test_access_and_startup_sweep_temp_and_unindexed_blob_files(self):
        source = self.write_source("sweep/kept.pdf", b"%PDF-kept")
        self.store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="file",
            location=str(source),
        )
        kept_blob = next(self.store.files_root.glob("*.blob"))

        access_orphan = self.store.files_root / ("art_" + "a" * 24 + ".blob")
        access_temporary = self.store.files_root / (
            ".art_" + "b" * 24 + "." + "c" * 32 + ".tmp"
        )
        access_index_temporary = self.root / (".index." + "d" * 32 + ".tmp")
        for path in (access_orphan, access_temporary, access_index_temporary):
            path.write_bytes(b"crash debris")

        self.store.list()

        self.assertTrue(kept_blob.exists())
        self.assertFalse(access_orphan.exists())
        self.assertFalse(access_temporary.exists())
        self.assertFalse(access_index_temporary.exists())

        startup_orphan = self.store.files_root / ("art_" + "e" * 24 + ".blob")
        startup_temporary = self.store.files_root / (
            ".art_" + "f" * 24 + "." + "0" * 32 + ".tmp"
        )
        startup_orphan.write_bytes(b"unindexed")
        startup_temporary.write_bytes(b"interrupted")

        ResultArtifactStore(self.root, environ={})

        self.assertTrue(kept_blob.exists())
        self.assertFalse(startup_orphan.exists())
        self.assertFalse(startup_temporary.exists())

    def test_storage_root_and_files_directory_must_not_be_symlinks(self):
        real_root = self.base / "real-root"
        real_root.mkdir()
        linked_root = self.base / "linked-root"
        external_files = self.base / "external-files"
        external_files.mkdir()
        try:
            linked_root.symlink_to(real_root, target_is_directory=True)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")

        with self.assertRaises(ResultArtifactError) as root_context:
            ResultArtifactStore(linked_root, environ={})
        self.assertEqual(
            root_context.exception.code,
            "result_artifact_storage_invalid",
        )

        root_with_linked_files = self.base / "root-with-linked-files"
        root_with_linked_files.mkdir()
        (root_with_linked_files / "files").symlink_to(
            external_files,
            target_is_directory=True,
        )
        with self.assertRaises(ResultArtifactError) as files_context:
            ResultArtifactStore(root_with_linked_files, environ={})
        self.assertEqual(
            files_context.exception.code,
            "result_artifact_storage_invalid",
        )

    def test_content_open_never_follows_a_blob_symlink(self):
        payload = b"%PDF-private"
        source = self.write_source("symlink-content/private.pdf", payload)
        artifact = self.store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="file",
            location=str(source),
        )
        blob = next(self.store.files_root.glob("*.blob"))
        blob.unlink()
        outside = self.base / "outside.pdf"
        outside.write_bytes(payload)
        blob.symlink_to(outside)

        with self.assertRaises(ResultArtifactError) as context:
            self.store.open_content(artifact["id"])

        self.assertEqual(context.exception.status, 404)
        self.assertEqual(
            context.exception.code,
            "result_artifact_content_unavailable",
        )
        self.assertEqual(outside.read_bytes(), payload)

    def test_list_is_newest_first_durable_and_prunes_to_configured_count(self):
        store = ResultArtifactStore(
            self.root,
            environ={"HERDR_HARNESS_RESULT_ARTIFACT_MAX_COUNT": "2"},
        )
        first = store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="link",
            location="https://example.com/first",
        )
        second = store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="link",
            location="https://example.com/second",
        )
        third = store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="link",
            location="https://example.com/third",
        )

        reopened = ResultArtifactStore(
            self.root,
            environ={"HERDR_HARNESS_RESULT_ARTIFACT_MAX_COUNT": "2"},
        )
        listed = reopened.list()
        self.assertEqual([item["id"] for item in listed], [third["id"], second["id"]])
        self.assertNotIn(first["id"], {item["id"] for item in listed})

    def test_retention_pruning_removes_expired_private_blob(self):
        source = self.write_source("expired.pdf", b"%PDF-old")
        artifact = self.store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="file",
            location=str(source),
        )
        payload = json.loads(self.store.index_path.read_text(encoding="utf-8"))
        payload["artifacts"][0]["createdAt"] = "2000-01-01T00:00:00.000Z"
        self.store.index_path.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaises(ResultArtifactError):
            self.store.open_content(artifact["id"])
        self.assertEqual(self.store.list(), [])
        self.assertFalse(any(self.store.files_root.iterdir()))

    def test_missing_blob_and_unknown_or_traversing_ids_return_not_found(self):
        source = self.write_source("movie.mp4", b"video bytes")
        artifact = self.store.create(
            origin_type="pane",
            origin_id="w1:p1",
            kind="file",
            location=str(source),
        )
        next(self.store.files_root.iterdir()).unlink()

        with self.assertRaises(ResultArtifactError) as context:
            self.store.open_content(artifact["id"])
        self.assertEqual(context.exception.status, 404)
        self.assertEqual(context.exception.code, "result_artifact_content_unavailable")

        for invalid_id in ("art_not-an-id", "../index.json", "art_" + "0" * 24):
            with self.subTest(invalid_id=invalid_id), self.assertRaises(ResultArtifactError) as raised:
                self.store.open_content(invalid_id)
            self.assertEqual(raised.exception.status, 404)


class ResultArtifactHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base_path = Path(self.temporary.name)
        store = ResultArtifactStore(self.base_path / "artifact-store", environ={})

        # These HTTP routes need only the small artifact-facing slice of the
        # service. Constructing it without the unrelated socket managers keeps
        # this focused test deterministic while exercising production methods.
        self.service = object.__new__(HerdrService)
        self.service.environ = {}
        self.service.broker = EventBroker()
        self.service._result_artifact_store = store
        self.service._result_artifact_store_lock = threading.Lock()

        self.server = make_server(
            self.service,
            host="127.0.0.1",
            port=0,
            api_token="artifact-secret",
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def _stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=1)

    def request_json(self, path: str, *, method: str = "GET", payload=None, token="artifact-secret"):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, response.headers, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            with exc:
                return exc.code, exc.headers, json.loads(exc.read())

    def test_authenticated_create_list_event_and_binary_content_contract(self):
        payload_bytes = b"\x00\x01video-result\xff"
        source = self.base_path / "preview.mp4"
        source.write_bytes(payload_bytes)
        create_status, _, created = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload={
                "originType": "agent_run",
                "originId": "agr_0123456789ab",
                "sessionId": "session-abc",
                "kind": "file",
                "location": str(source),
                "title": "Futuristic preview",
                "idempotencyKey": "pr_" + "b" * 64,
            },
        )

        self.assertEqual(create_status, 201)
        artifact = created["artifact"]
        self.assertTrue(created["ok"])
        self.assertEqual(artifact["byteSize"], len(payload_bytes))
        self.assertNotIn(str(source), json.dumps(created))

        retry_status, _, retried = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload={
                "originType": "agent_run",
                "originId": "agr_0123456789ab",
                "sessionId": "session-abc",
                "kind": "file",
                "location": str(source),
                "title": "Futuristic preview",
                "idempotencyKey": "pr_" + "b" * 64,
            },
        )
        self.assertEqual(retry_status, 201)
        self.assertEqual(retried, created)

        list_status, _, listed = self.request_json("/api/v1/result-artifacts")
        self.assertEqual(list_status, 200)
        self.assertEqual(listed, {"ok": True, "artifacts": [artifact]})

        events = self.service.broker.after(0)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event"], "result_artifact.created")
        self.assertEqual(events[0]["data"], artifact)

        request = urllib.request.Request(
            self.base_url + artifact["downloadPath"],
            headers={"Authorization": "Bearer artifact-secret"},
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            downloaded = response.read()
            headers = response.headers
            status = response.status
        self.assertEqual(status, 200)
        self.assertEqual(downloaded, payload_bytes)
        self.assertEqual(headers["Content-Type"], "video/mp4")
        self.assertEqual(int(headers["Content-Length"]), len(payload_bytes))
        self.assertIn("preview.mp4", headers["Content-Disposition"])
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

    def test_idempotency_conflict_returns_409_without_second_event(self):
        base_payload = {
            "originType": "pane",
            "originId": "w1:p1",
            "kind": "link",
            "location": "https://example.com/first",
            "idempotencyKey": "pr_http_collision",
        }
        first_status, _, _ = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload=base_payload,
        )
        conflicting_payload = dict(base_payload)
        conflicting_payload["location"] = "https://example.com/second"
        conflict_status, _, conflict = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload=conflicting_payload,
        )

        self.assertEqual(first_status, 201)
        self.assertEqual(conflict_status, 409)
        self.assertEqual(
            conflict["error"]["code"],
            "result_artifact_idempotency_conflict",
        )
        self.assertEqual(len(self.service.broker.after(0)), 1)

    def test_routes_require_auth_and_reject_traversal_symlink_and_missing_content(self):
        unauthorized, _, body = self.request_json(
            "/api/v1/result-artifacts", token=None
        )
        self.assertEqual(unauthorized, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")

        source = self.base_path / "report.pdf"
        source.write_bytes(b"%PDF")
        symlink = self.base_path / "alias.pdf"
        symlink.symlink_to(source)
        status, _, rejected = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload={
                "originType": "pane",
                "originId": "w1:p1",
                "kind": "file",
                "location": str(symlink),
            },
        )
        self.assertEqual(status, 400)
        self.assertEqual(rejected["error"]["code"], "invalid_result_artifact")

        missing_status, _, missing = self.request_json(
            "/api/v1/result-artifacts/art_000000000000000000000000/content"
        )
        self.assertEqual(missing_status, 404)
        self.assertEqual(missing["error"]["code"], "result_artifact_not_found")

        traversal_status, _, traversal = self.request_json(
            "/api/v1/result-artifacts/%2E%2E/content"
        )
        self.assertEqual(traversal_status, 404)
        self.assertEqual(traversal["error"]["code"], "result_artifact_not_found")

    def test_create_rejects_unknown_fields_and_non_http_links(self):
        status, _, body = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload={
                "originType": "pane",
                "originId": "w1:p1",
                "kind": "link",
                "location": "https://example.com",
                "sourcePath": "/private/secret",
            },
        )
        self.assertEqual(status, 400)
        self.assertIn("unsupported field", body["error"]["message"])

        status, _, body = self.request_json(
            "/api/v1/result-artifacts",
            method="POST",
            payload={
                "originType": "pane",
                "originId": "w1:p1",
                "kind": "link",
                "location": "file:///private/tmp/result.html",
            },
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_result_artifact")


if __name__ == "__main__":
    unittest.main()
