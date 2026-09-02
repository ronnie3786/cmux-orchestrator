import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from herdr_harness import secret_file
from herdr_harness import response_audio


class _FakeResponse:
    def __init__(self, payload: bytes, status: int = 200):
        self.payload = payload
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self, maximum: int = -1) -> bytes:
        return self.payload if maximum < 0 else self.payload[:maximum]


class _ResponseAudioOpener:
    def __init__(self):
        self.requests = []

    def __call__(self, request, *, timeout):
        self.requests.append((request, timeout))
        if request.full_url.endswith("/health"):
            return _FakeResponse(b'{"status":"healthy"}')
        if request.full_url.endswith("/models"):
            if request.headers.get("Authorization") != "Bearer test-secret":
                raise AssertionError("summary probe must use the configured Pi provider key")
            return _FakeResponse(b'{"data":[]}')
        if request.full_url.endswith("/chat/completions"):
            body = json.loads(request.data.decode("utf-8"))
            if body["model"] != response_audio.DEFAULT_SUMMARY_MODEL:
                raise AssertionError("unexpected summary model")
            return _FakeResponse(
                json.dumps(
                    {
                        "choices": [
                            {
                                "message": {
                                    "content": "The build passed. Install the update and verify playback."
                                }
                            }
                        ]
                    }
                ).encode("utf-8")
            )
        if request.full_url.endswith("/audio/speech"):
            body = json.loads(request.data.decode("utf-8"))
            if body["voice"] != "af_jessica":
                raise AssertionError("unexpected Kokoro voice")
            return _FakeResponse(b"I" * 640)
        raise AssertionError(f"unexpected request: {request.full_url}")


class ResponseAudioTextTests(unittest.TestCase):
    def test_markdown_becomes_readable_prose(self):
        source = """# Result

- **Build passed** in [`App.swift`](https://example.com/app).
- Visit https://example.com/logs

```swift
print("done")
```
"""
        self.assertEqual(
            response_audio.to_speakable_text(source),
            'Result\n\nBuild passed in App.swift.\nVisit\n\nprint("done")',
        )

    def test_chunks_respect_the_requested_limit(self):
        source = " ".join(["sentence."] * 1_000)
        chunks = response_audio.split_speech_chunks(source, 500)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(0 < len(chunk) <= 500 for chunk in chunks))
        self.assertEqual(" ".join(" ".join(chunks).split()), source)

    def test_invalid_generated_summary_falls_back_to_source(self):
        source = " ".join(["important"] * 100)
        self.assertEqual(
            response_audio.finalize_tldr_text(source, "The response says nothing useful."),
            source,
        )


class ResponseAudioServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        (root / "models.json").write_text(
            json.dumps(
                {
                    "providers": {
                        response_audio.DEFAULT_SUMMARY_PROVIDER: {
                            "baseUrl": "http://summary.test/v1",
                            "apiKey": "test-secret",
                            "authHeader": True,
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        self.opener = _ResponseAudioOpener()
        self.service = response_audio.ResponseAudioService(
            {
                "PI_CODING_AGENT_DIR": self.temporary.name,
                "HERDR_RESPONSE_AUDIO_TTS_URL": "http://tts.test",
            },
            opener=self.opener,
            clock=lambda: 100,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def _write_local_tts_config(self, value):
        path = Path(self.temporary.name) / ".config" / "herdr-harness" / "response-audio.json"
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(0o600)
        return path

    def _local_service(self, *, opener=None, extra_environment=None):
        environment = {"HOME": self.temporary.name}
        if extra_environment:
            environment.update(extra_environment)
        return response_audio.ResponseAudioService(
            environment,
            opener=opener or self.opener,
            clock=lambda: 100,
        )

    def test_tts_environment_takes_precedence_over_local_config(self):
        self._write_local_tts_config({"ttsUrl": "http://local.test"})
        service = self._local_service(
            extra_environment={"HERDR_RESPONSE_AUDIO_TTS_URL": "http://environment.test///"}
        )
        self.assertEqual(service.tts_endpoint, "http://environment.test/v1/audio/speech")
        self.assertEqual(service.tts_health_endpoint, "http://environment.test/health")

        service = self._local_service(extra_environment={"HERDR_RESPONSE_AUDIO_TTS_URL": "  "})
        self.assertEqual(service.tts_endpoint, "http://local.test/v1/audio/speech")

    def test_local_tts_base_and_full_speech_urls_are_normalized(self):
        self._write_local_tts_config({"ttsUrl": "http://local.test///"})
        service = self._local_service()
        self.assertEqual(service.tts_endpoint, "http://local.test/v1/audio/speech")
        self.assertEqual(service.tts_health_endpoint, "http://local.test/health")

        self._write_local_tts_config({"ttsUrl": "http://local.test/v1/audio/speech///"})
        service = self._local_service()
        self.assertEqual(service.tts_endpoint, "http://local.test/v1/audio/speech")

    def test_config_path_requires_absolute_non_nul_home(self):
        self.assertIsNone(response_audio._response_audio_config_path({"HOME": "relative-home"}))
        self.assertIsNone(response_audio._response_audio_config_path({"HOME": "/tmp/invalid\x00home"}))

    def test_missing_malformed_unreadable_and_non_regular_config_are_safe(self):
        opener = lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("network used"))
        service = self._local_service(opener=opener)
        self.assertIsNone(service.tts_endpoint)
        self.assertEqual(
            service.capabilities(),
            {"ok": True, "available": False, "listen": False, "tldr": False},
        )

        path = self._write_local_tts_config({"ttsUrl": "http://local.test"})
        path.write_text("not json", encoding="utf-8")
        self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

        path.write_bytes(b"\xff")
        self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

        path.write_text(json.dumps({"ttsUrl": "http://local.test"}), encoding="utf-8")
        with mock.patch.object(
            response_audio,
            "load_private_file_bytes",
            side_effect=secret_file.SecretFileError("permission denied"),
        ):
            self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

        path.write_text(
            json.dumps({"ttsUrl": "x" * (response_audio.RESPONSE_AUDIO_CONFIG_MAX_BYTES + 1)}),
            encoding="utf-8",
        )
        self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

        path.unlink()
        path.mkdir()
        self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

        path.rmdir()
        target = path.with_name("response-audio-target.json")
        target.write_text(json.dumps({"ttsUrl": "http://local.test"}), encoding="utf-8")
        path.symlink_to(target)
        self.assertIsNone(self._local_service(opener=opener).tts_endpoint)

    def test_local_config_requires_private_owner_and_stable_inode(self):
        path = self._write_local_tts_config({"ttsUrl": "http://local.test"})
        for mode in (0o644, 0o660):
            with self.subTest(mode=oct(mode)):
                path.chmod(mode)
                self.assertIsNone(self._local_service().tts_endpoint)
        path.chmod(0o600)

        with mock.patch.object(secret_file.os, "getuid", return_value=os.getuid() + 1):
            self.assertIsNone(self._local_service().tts_endpoint)

        real_fstat = secret_file.os.fstat

        def changed_inode(file_descriptor):
            metadata = real_fstat(file_descriptor)
            values = list(metadata)
            values[1] += 1
            return os.stat_result(values)

        with mock.patch.object(secret_file.os, "fstat", side_effect=changed_inode):
            self.assertIsNone(self._local_service().tts_endpoint)

    def test_invalid_tts_url_is_unavailable_without_generic_failure(self):
        opener = lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("network used"))
        for environment in (
            {"HERDR_RESPONSE_AUDIO_TTS_URL": "http://["},
            {},
        ):
            with self.subTest(environment=environment):
                if not environment:
                    self._write_local_tts_config({"ttsUrl": "http://["})
                service = self._local_service(opener=opener, extra_environment=environment)
                self.assertEqual(
                    service.capabilities(),
                    {"ok": True, "available": False, "listen": False, "tldr": False},
                )

    def test_missing_tts_configuration_reports_unavailable_action(self):
        service = self._local_service(
            opener=lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("network used"))
        )
        with self.assertRaises(response_audio.ResponseAudioError) as raised:
            service.prepare(action="listen", text="Hello")
        self.assertEqual(raised.exception.code, "response_audio_unavailable")
        self.assertEqual(raised.exception.status, 503)

    def test_capabilities_probe_private_services_and_cache_result(self):
        expected = {"ok": True, "available": True, "listen": True, "tldr": True}
        self.assertEqual(self.service.capabilities(), expected)
        self.assertEqual(self.service.capabilities(), expected)
        self.assertEqual(len(self.opener.requests), 2)

    def test_prepare_tldr_and_synthesize_audio(self):
        source = " ".join(["Detailed release information."] * 60)
        prepared = self.service.prepare(action="tldr", text=source)
        self.assertEqual(prepared["action"], "tldr")
        self.assertEqual(
            prepared["chunks"],
            ["The build passed. Install the update and verify playback."],
        )

        speech = self.service.synthesize(text=prepared["chunks"][0])
        self.assertEqual(speech["contentType"], "audio/mpeg")
        self.assertGreater(len(speech["audioBase64"]), 800)

    def test_feature_can_be_disabled_without_network_requests(self):
        disabled = response_audio.ResponseAudioService(
            {"HERDR_RESPONSE_AUDIO_ENABLED": "false"},
            opener=lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("network used")),
        )
        self.assertEqual(
            disabled.capabilities(),
            {"ok": True, "available": False, "listen": False, "tldr": False},
        )


if __name__ == "__main__":
    unittest.main()
