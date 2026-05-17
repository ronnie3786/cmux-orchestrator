from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from . import cmux_cli
from . import orchestrator_v2_storage as v2
from . import tailscale
from .orchestrator_v2_security import load_local_env, redact_text, repo_root


DEFAULT_SIDECAR_PORT = 8792
DEFAULT_PYTHON_PORT = 9091


def sidecar_dir() -> Path:
    return repo_root() / "agent" / "orchestrator-v2"


def sidecar_port() -> int:
    return int(os.environ.get("ORCHESTRATOR_V2_AGENT_PORT") or DEFAULT_SIDECAR_PORT)


def sidecar_base_url() -> str:
    configured = str(os.environ.get("ORCHESTRATOR_V2_AGENT_URL") or "").strip().rstrip("/")
    if configured:
        return configured
    return f"http://127.0.0.1:{sidecar_port()}"


def python_base_url(port: int | None = None) -> str:
    configured = str(os.environ.get("ORCHESTRATOR_V2_PYTHON_BASE_URL") or "").strip().rstrip("/")
    if configured:
        return configured
    return f"http://127.0.0.1:{int(port or DEFAULT_PYTHON_PORT)}"


def sidecar_health(timeout: float = 1.5) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(f"{sidecar_base_url()}/health", timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
            return {"ok": True, **payload}
    except Exception as exc:
        return {"ok": False, "error": redact_text(str(exc)), "url": sidecar_base_url()}


def proxy_json(path: str, payload: dict[str, Any], *, timeout: float = 120.0) -> dict[str, Any]:
    body = json.dumps(payload or {}).encode("utf-8")
    request = urllib.request.Request(
        f"{sidecar_base_url()}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode("utf-8")
            return json.loads(text or "{}")
    except urllib.error.HTTPError as exc:
        try:
            data = json.loads(exc.read().decode("utf-8") or "{}")
        except Exception:
            data = {"error": exc.reason}
        return {"ok": False, "status": exc.code, "error": redact_text(data.get("error") or exc.reason)}
    except Exception as exc:
        return {"ok": False, "status": 503, "error": f"Node sidecar unavailable: {redact_text(exc)}"}


def proxy_stream(handler, path: str, payload: dict[str, Any], *, timeout: float = 120.0) -> bool:
    body = json.dumps(payload or {}).encode("utf-8")
    request = urllib.request.Request(
        f"{sidecar_base_url()}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except Exception as exc:
        handler._json_response({"ok": False, "error": f"Node sidecar unavailable: {redact_text(exc)}"}, 503)
        return True

    try:
        handler.send_response(getattr(response, "status", 200) or 200)
        handler.send_header("Content-Type", response.headers.get("Content-Type") or "text/event-stream; charset=utf-8")
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("X-Accel-Buffering", "no")
        handler.end_headers()
        while True:
            chunk = response.read(8192)
            if not chunk:
                break
            handler.wfile.write(chunk)
            try:
                handler.wfile.flush()
            except AttributeError:
                pass
    except (BrokenPipeError, ConnectionResetError):
        return True
    finally:
        response.close()
    return True


class OrchestratorV2Sidecar:
    def __init__(self, *, python_port: int = DEFAULT_PYTHON_PORT, port: int | None = None):
        self.python_port = int(python_port or DEFAULT_PYTHON_PORT)
        self.port = int(port or sidecar_port())
        self.process: subprocess.Popen | None = None

    def start(self) -> bool:
        if os.environ.get("ORCHESTRATOR_V2_DISABLE_SIDECAR", "").strip().lower() in {"1", "true", "yes"}:
            return False
        if sidecar_health(timeout=0.4).get("ok"):
            return False
        target = sidecar_dir()
        if not (target / "package.json").exists():
            return False
        env = os.environ.copy()
        load_local_env()
        env.update(os.environ)
        env.setdefault("PORT", str(self.port))
        env.setdefault("ORCHESTRATOR_V2_AGENT_PORT", str(self.port))
        env.setdefault("ORCHESTRATOR_V2_PYTHON_BASE_URL", python_base_url(self.python_port))
        env.setdefault("NODE_ENV", "production-local")
        try:
            self.process = subprocess.Popen(
                ["npm", "start", "--", "--host", "127.0.0.1"],
                cwd=str(target),
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, FileNotFoundError):
            self.process = None
            return False
        return True

    def stop(self) -> None:
        if not self.process:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


def _command_status(command: list[str], *, timeout: float = 4.0) -> dict[str, Any]:
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return {"available": False, "error": f"{command[0]} not found"}
    except Exception as exc:
        return {"available": False, "error": redact_text(exc)}
    text = (completed.stdout or completed.stderr or "").strip().splitlines()
    return {
        "available": completed.returncode == 0,
        "exitCode": completed.returncode,
        "version": redact_text(text[0]) if text else "",
        "error": "" if completed.returncode == 0 else redact_text(completed.stderr or completed.stdout),
    }


def health_payload(*, python_port: int = DEFAULT_PYTHON_PORT, repo: v2.V2Repository | None = None) -> dict[str, Any]:
    load_local_env()
    repository = repo or v2.get_repository()
    port = int(python_port or DEFAULT_PYTHON_PORT)
    sqlite_ok = False
    try:
        repository.initialize()
        sqlite_ok = repository.db_path.exists()
    except Exception:
        sqlite_ok = False
    try:
        cmux_binary = cmux_cli.get_cli().binary()
        cmux_available = bool(cmux_binary and Path(cmux_binary).exists())
    except Exception:
        cmux_binary = ""
        cmux_available = False
    try:
        import importlib.util
        faster_whisper_available = importlib.util.find_spec("faster_whisper") is not None
    except Exception:
        faster_whisper_available = False
    piper_binary = os.environ.get("ORCHESTRATOR_V2_PIPER_BIN") or shutil.which("piper") or ""
    piper_voice_path = os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE_PATH") or os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE") or ""
    if piper_voice_path and not os.path.isabs(piper_voice_path):
        piper_voice_path = str((repo_root() / piper_voice_path).expanduser())
    tailscale_status = tailscale.detect_tailscale(port=port)
    checks = {
        "pythonApi": {"available": True, "version": sys.version.split()[0]},
        "node": _command_status(["node", "--version"]),
        "npm": _command_status(["npm", "--version"]),
        "nodeSidecar": sidecar_health(timeout=0.5),
        "fireworks": {
            "available": bool(os.environ.get("FIREWORKS_API_KEY")),
            "provider": os.environ.get("ORCHESTRATOR_V2_AGENT_PROVIDER") or "fireworks",
            "model": os.environ.get("ORCHESTRATOR_V2_AGENT_MODEL") or "accounts/fireworks/models/minimax-m2p7",
        },
        "openaiRealtime": {
            "available": bool(os.environ.get("OPENAI_API_KEY")),
            "model": os.environ.get("OPENAI_REALTIME_MODEL") or "gpt-realtime-2",
            "voice": os.environ.get("REALTIME_VOICE") or "marin",
        },
        "elevenlabs": {"available": bool(os.environ.get("ELEVENLABS_API_KEY")), "optional": True},
        "cmuxCli": {"available": cmux_available, "path": cmux_binary},
        "fasterWhisper": {
            "available": faster_whisper_available,
            "model": os.environ.get("ORCHESTRATOR_V2_STT_MODEL") or "base.en",
        },
        "piper": {
            "available": bool(piper_binary),
            "binary": piper_binary,
            "voicePathAvailable": bool(piper_voice_path and Path(piper_voice_path).expanduser().exists()),
            "voice": os.environ.get("ORCHESTRATOR_V2_PIPER_VOICE") or "en_US-amy-medium.onnx",
            "lengthScale": os.environ.get("ORCHESTRATOR_V2_PIPER_LENGTH_SCALE") or "0.67",
        },
        "sqlite": {"available": sqlite_ok, "path": str(repository.db_path)},
        "tailscale": {
            "available": bool(tailscale_status.get("tailscaleIPv4") or tailscale_status.get("dnsName")),
            **tailscale_status,
        },
    }
    required = ["pythonApi", "node", "npm", "fireworks", "openaiRealtime", "cmuxCli", "sqlite"]
    ok = all(bool(checks[name].get("available") or checks[name].get("ok")) for name in required)
    return {"ok": ok, "checks": checks, "sidecarUrl": sidecar_base_url()}
