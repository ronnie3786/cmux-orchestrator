from __future__ import annotations

import base64
import http.client
import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path
from typing import Any

from .orchestrator_v2_security import load_local_env, redact_text, repo_root


MAX_STT_AUDIO_BYTES = 20 * 1024 * 1024
MAX_STT_JSON_BYTES = 29 * 1024 * 1024
MAX_STT_RESPONSE_BYTES = 512 * 1024
_SAFE_AUDIO_FILENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.wav$", re.IGNORECASE)


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep private voice recordings on the configured Parakeet origin."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_RejectRedirects())


def parakeet_base_url() -> str:
    return str(os.environ.get("ORCHESTRATOR_V2_PARAKEET_URL") or "http://127.0.0.1:18793").strip().rstrip("/")


def kokoro_base_url() -> str:
    return str(os.environ.get("ORCHESTRATOR_V2_KOKORO_URL") or "http://127.0.0.1:8898").strip().rstrip("/")


def _tiny_wav_bytes() -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = Path(tmp.name)
    try:
        with wave.open(str(path), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\x00\x00" * 1600)
        return path.read_bytes()
    finally:
        try:
            path.unlink()
        except OSError:
            pass


def _payload_is_wav(data: dict[str, Any]) -> bool:
    mime = str(data.get("mimeType") or "").strip().lower().split(";", 1)[0]
    if mime and mime not in {"audio/wav", "audio/x-wav", "audio/wave"}:
        return False
    filename = str(data.get("filename") or "").strip().lower()
    if filename and "." in filename and not filename.endswith(".wav"):
        return False
    return True


def transcribe_local_payload(data: dict[str, Any]) -> dict[str, Any]:
    load_local_env()
    started = time.monotonic()
    partial = bool(data.get("partial"))
    if os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_VOICE", "").strip().lower() in {"1", "true", "yes", "on"}:
        return {
            "ok": True,
            "text": str(data.get("fixtureText") or "fixture audio transcript"),
            "backend": "fake",
            "partial": partial,
            "elapsedS": round(time.monotonic() - started, 3),
        }

    audio_b64 = str(data.get("audioBase64") or "").strip()
    if not audio_b64:
        raise ValueError("audioBase64 required")
    maximum_encoded = ((MAX_STT_AUDIO_BYTES + 2) // 3) * 4
    if len(audio_b64) > maximum_encoded:
        raise ValueError("audio exceeds 20 MB limit")
    try:
        audio_bytes = base64.b64decode(audio_b64, validate=True)
    except Exception as exc:
        raise ValueError("audioBase64 is invalid") from exc
    if not audio_bytes:
        raise ValueError("audioBase64 is empty")
    if len(audio_bytes) > MAX_STT_AUDIO_BYTES:
        raise ValueError("audio exceeds 20 MB limit")

    backend = str(data.get("backend") or os.environ.get("ORCHESTRATOR_V2_STT_BACKEND") or "parakeet").strip().lower()
    parakeet_error = ""
    if backend == "parakeet" and _payload_is_wav(data):
        try:
            text = _transcribe_parakeet(audio_bytes, str(data.get("filename") or "audio.wav"))
            return {
                "ok": True,
                "text": text,
                "backend": "parakeet",
                "partial": partial,
                "elapsedS": round(time.monotonic() - started, 3),
            }
        except urllib.error.HTTPError as exc:
            parakeet_error = f"HTTP {exc.code}"
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            parakeet_error = redact_text(exc)

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:
        if parakeet_error:
            raise RuntimeError(
                f"Parakeet failed ({parakeet_error}) and faster-whisper is not installed or importable"
            ) from exc
        raise RuntimeError("faster-whisper is not installed or importable") from exc

    suffix = str(data.get("filename") or "audio.webm")
    suffix = "." + suffix.rsplit(".", 1)[-1] if "." in suffix else ".webm"
    model_name = os.environ.get("ORCHESTRATOR_V2_STT_MODEL") or "base.en"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(audio_bytes)
        audio_path = Path(tmp.name)
    try:
        model = WhisperModel(model_name, device=os.environ.get("ORCHESTRATOR_V2_STT_DEVICE") or "auto")
        segments, info = model.transcribe(str(audio_path), beam_size=1)
        text = " ".join(segment.text.strip() for segment in segments if getattr(segment, "text", "").strip()).strip()
        return {
            "ok": True,
            "text": text,
            "backend": "faster-whisper",
            "model": model_name,
            "language": getattr(info, "language", ""),
            "partial": partial,
            "elapsedS": round(time.monotonic() - started, 3),
        }
    finally:
        try:
            audio_path.unlink()
        except OSError:
            pass


def _transcribe_parakeet(audio_bytes: bytes, filename: str) -> str:
    filename = Path(filename).name
    if not _SAFE_AUDIO_FILENAME_RE.fullmatch(filename):
        raise ValueError("audio filename is invalid")
    try:
        with wave.open(io.BytesIO(audio_bytes), "rb") as audio:
            if (
                audio.getcomptype() != "NONE"
                or audio.getnchannels() != 1
                or audio.getframerate() != 16_000
                or audio.getsampwidth() != 2
                or audio.getnframes() <= 0
                or audio.getnframes() > 16_000 * 10 * 60
            ):
                raise ValueError("audio must be mono 16 kHz, 16-bit PCM WAV")
    except (EOFError, wave.Error) as exc:
        raise ValueError("audio must be a valid PCM WAV file") from exc
    boundary = uuid.uuid4().hex
    body = (
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="audio"; filename="{filename}"\r\n'
            "Content-Type: audio/wav\r\n\r\n"
        ).encode("utf-8")
        + audio_bytes
        + f"\r\n--{boundary}--\r\n".encode("utf-8")
    )
    request = urllib.request.Request(
        f"{parakeet_base_url()}/transcribe",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        timeout = float(os.environ.get("ORCHESTRATOR_V2_PARAKEET_TIMEOUT_SECONDS") or 60)
    except (TypeError, ValueError):
        timeout = 60
    timeout = min(max(timeout, 5), 120)
    with _NO_REDIRECT_OPENER.open(request, timeout=timeout) as response:
        content_length = response.headers.get("Content-Length")
        if content_length:
            try:
                declared_length = int(content_length)
            except ValueError:
                declared_length = 0
            if declared_length > MAX_STT_RESPONSE_BYTES:
                raise ValueError("Parakeet response exceeds the size limit")
        response_data = response.read(MAX_STT_RESPONSE_BYTES + 1)
    if len(response_data) > MAX_STT_RESPONSE_BYTES:
        raise ValueError("Parakeet response exceeds the size limit")
    try:
        payload = json.loads(response_data.decode("utf-8") or "{}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("Parakeet returned invalid JSON") from exc
    if not isinstance(payload, dict):
        raise ValueError("Parakeet returned an invalid response")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Parakeet returned an empty transcript")
    return text.strip()


def _truncate_speech_text(text: str, limit: int = 1200) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    clipped = text[:limit]
    boundary = max(clipped.rfind("."), clipped.rfind("!"), clipped.rfind("?"))
    if boundary > 0:
        return clipped[: boundary + 1].strip(), True
    whitespace = max(clipped.rfind(" "), clipped.rfind("\n"), clipped.rfind("\t"))
    if whitespace > 0:
        return clipped[:whitespace].strip(), True
    return clipped, True


def speak_local_payload(data: dict[str, Any]) -> dict[str, Any]:
    load_local_env()
    text = str(data.get("text") or "").strip()
    if not text:
        raise ValueError("text required")
    text, truncated = _truncate_speech_text(text)
    provider = str(data.get("provider") or os.environ.get("ORCHESTRATOR_V2_TTS_BACKEND") or "kokoro").strip().lower()
    if provider == "elevenlabs":
        result = _speak_elevenlabs(text)
    elif provider == "piper":
        result = _speak_piper(text)
    else:
        result = _speak_kokoro(text, data)
    if truncated:
        result["truncated"] = True
    return result


def _speak_kokoro(text: str, data: dict[str, Any]) -> dict[str, Any]:
    started = time.monotonic()
    voice = str(data.get("voice") or os.environ.get("ORCHESTRATOR_V2_KOKORO_VOICE") or "bm_daniel").strip()
    speed = float(data.get("speed") or 1.0)
    if os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_VOICE", "").strip().lower() in {"1", "true", "yes", "on"}:
        return {
            "ok": True,
            "provider": "kokoro",
            "mimeType": "audio/wav",
            "audioBase64": base64.b64encode(_tiny_wav_bytes()).decode("ascii"),
            "voice": voice,
            "elapsedS": round(time.monotonic() - started, 3),
        }
    payload = {
        "model": "kokoro",
        "voice": voice,
        "input": text,
        "response_format": "wav",
        "speed": speed,
    }
    request = urllib.request.Request(
        f"{kokoro_base_url()}/v1/audio/speech",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            audio = response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Kokoro request failed: HTTP {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"Kokoro request failed: {redact_text(exc)}") from exc
    return {
        "ok": True,
        "provider": "kokoro",
        "mimeType": "audio/wav",
        "audioBase64": base64.b64encode(audio).decode("ascii"),
        "voice": voice,
        "elapsedS": round(time.monotonic() - started, 3),
    }


def _speak_piper(text: str) -> dict[str, Any]:
    if os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_VOICE", "").strip().lower() in {"1", "true", "yes", "on"}:
        return {
            "ok": True,
            "provider": "piper",
            "mimeType": "audio/wav",
            "audioBase64": base64.b64encode(_tiny_wav_bytes()).decode("ascii"),
            "voice": os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE") or "en_US-amy-medium.onnx",
            "lengthScale": os.environ.get("ORCHESTRATOR_V2_PIPER_LENGTH_SCALE") or "0.67",
        }
    binary = os.environ.get("ORCHESTRATOR_V2_PIPER_BIN") or shutil.which("piper")
    if not binary:
        raise RuntimeError("Piper binary is not available")
    voice_path = os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE_PATH") or os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE") or "en_US-amy-medium.onnx"
    voice = Path(voice_path).expanduser()
    if not voice.is_absolute():
        voice = repo_root() / voice
    if not voice.exists():
        raise RuntimeError(f"Piper voice model unavailable: {voice.name}")
    length_scale = os.environ.get("ORCHESTRATOR_V2_PIPER_LENGTH_SCALE") or "0.67"
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        output_path = Path(tmp.name)
    try:
        completed = subprocess.run(
            [
                binary,
                "--model",
                str(voice),
                "--output_file",
                str(output_path),
                "--length-scale",
                str(length_scale),
            ],
            input=text,
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(redact_text(completed.stderr or completed.stdout or "Piper failed"))
        return {
            "ok": True,
            "provider": "piper",
            "mimeType": "audio/wav",
            "audioBase64": base64.b64encode(output_path.read_bytes()).decode("ascii"),
            "voice": voice.name,
            "lengthScale": length_scale,
        }
    finally:
        try:
            output_path.unlink()
        except OSError:
            pass


def _speak_elevenlabs(text: str) -> dict[str, Any]:
    api_key = os.environ.get("ELEVENLABS_API_KEY")
    if not api_key:
        raise RuntimeError("ELEVENLABS_API_KEY is not configured")
    voice_id = os.environ.get("ORCHESTRATOR_V2_ELEVENLABS_VOICE_ID") or "cgSgspJ2msm6clMCkdW9"
    payload = {
        "text": text,
        "model_id": os.environ.get("ORCHESTRATOR_V2_ELEVENLABS_MODEL") or "eleven_multilingual_v2",
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.75},
    }
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
            "xi-api-key": api_key,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            audio = response.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"ElevenLabs request failed: HTTP {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"ElevenLabs request failed: {redact_text(exc)}") from exc
    return {
        "ok": True,
        "provider": "elevenlabs",
        "mimeType": "audio/mpeg",
        "audioBase64": base64.b64encode(audio).decode("ascii"),
        "voiceId": voice_id,
        "voiceName": os.environ.get("ORCHESTRATOR_V2_ELEVENLABS_VOICE_NAME") or "Jessica",
    }


def realtime_client_secret_payload(data: dict[str, Any]) -> dict[str, Any]:
    load_local_env()
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not configured")
    model = os.environ.get("OPENAI_REALTIME_MODEL") or "gpt-realtime-2"
    voice = os.environ.get("REALTIME_VOICE") or "marin"
    tools = data.get("tools") if isinstance(data.get("tools"), list) else []
    session = {
        "type": "realtime",
        "model": model,
        "instructions": str(data.get("instructions") or "You are the Orchestrator V2 voice agent. Use tools through the local backend safety layer."),
        "tools": tools,
        "tool_choice": "auto",
        "audio": {
            "input": {
                "turn_detection": {
                    "type": "server_vad",
                    "create_response": True,
                    "interrupt_response": True,
                }
            },
            "output": {"voice": voice},
        },
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/realtime/client_secrets",
        data=json.dumps({"session": session}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"OpenAI Realtime session failed: HTTP {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"OpenAI Realtime session failed: {redact_text(exc)}") from exc
    return {
        "ok": True,
        "model": model,
        "voice": voice,
        "turnDetection": "server_vad",
        "bargeIn": True,
        "pushToTalkAvailable": True,
        "clientSecret": payload,
    }
