"""Optional APNs delivery for Herdr agent transition alerts.

APNs requires HTTP/2, which Python's standard library HTTP client does not
implement. This module keeps the Python dependency surface standard-library
only and invokes the system ``curl --http2`` and ``openssl`` executables when
APNs credentials are explicitly configured. With no credentials it remains a
safe, no-op delivery layer while device registration still persists locally.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from typing import Callable, Mapping, Optional

from .alerts import utc_now


_TOKEN_RE = re.compile(r"^[0-9a-f]{32,256}$")
_BUNDLE_RE = re.compile(r"^[A-Za-z0-9.-]{1,255}$")


def _normalize_token(value: str) -> str:
    token = str(value or "").strip().lower().replace("<", "").replace(">", "").replace(" ", "")
    if not _TOKEN_RE.fullmatch(token) or len(token) % 2:
        raise ValueError("deviceToken must be a hexadecimal APNs token")
    return token


def _environment(value: str) -> str:
    return "production" if str(value or "").strip().lower() == "production" else "sandbox"


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _b64url_json(value: dict) -> str:
    return _b64url(json.dumps(value, separators=(",", ":")).encode("utf-8"))


def _read_der_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise ValueError("invalid ECDSA signature length")
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    if count == 0 or count > 4 or offset + count > len(data):
        raise ValueError("invalid ECDSA signature length")
    return int.from_bytes(data[offset : offset + count], "big"), offset + count


def _read_der_integer(data: bytes, offset: int) -> tuple[bytes, int]:
    if offset >= len(data) or data[offset] != 0x02:
        raise ValueError("invalid ECDSA integer")
    length, offset = _read_der_length(data, offset + 1)
    end = offset + length
    if length == 0 or end > len(data):
        raise ValueError("invalid ECDSA integer")
    value = data[offset:end].lstrip(b"\x00")
    if len(value) > 32:
        raise ValueError("ECDSA integer exceeds P-256 width")
    return value, end


def _der_to_raw_signature(data: bytes) -> bytes:
    if not data or data[0] != 0x30:
        raise ValueError("invalid ECDSA signature")
    sequence_length, offset = _read_der_length(data, 1)
    sequence_end = offset + sequence_length
    if sequence_end != len(data):
        raise ValueError("invalid ECDSA signature size")
    r_value, offset = _read_der_integer(data, offset)
    s_value, offset = _read_der_integer(data, offset)
    if offset != sequence_end:
        raise ValueError("invalid ECDSA signature fields")
    return r_value.rjust(32, b"\x00") + s_value.rjust(32, b"\x00")


class APNsManager:
    """Persist APNs devices and deliver Herdr alerts when configured."""

    def __init__(
        self,
        *,
        environ: Optional[Mapping[str, str]] = None,
        store_path: Optional[Path] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        home = Path(self.environ.get("HOME") or Path.home())
        configured_path = self.environ.get("HERDR_HARNESS_PUSH_STORE_PATH")
        self.store_path = Path(store_path or configured_path or home / ".config" / "herdr-harness" / "push-devices.json")
        self._lock = threading.RLock()
        self._jwt_token = ""
        self._jwt_created_at = 0
        self._delivery_ids: set[str] = set()
        self._delivery_order: deque[str] = deque()

    def _read(self) -> dict:
        try:
            with self.store_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return {"version": 1, "devices": {}}
        if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
            return {"version": 1, "devices": {}}
        return payload

    def _write(self, payload: dict) -> None:
        self.store_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=str(self.store_path.parent),
                prefix=".push-devices-",
                suffix=".json",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                json.dump(payload, handle, separators=(",", ":"), ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_path, 0o600)
            os.replace(temporary_path, self.store_path)
        finally:
            if temporary_path is not None and temporary_path.exists():
                try:
                    temporary_path.unlink()
                except OSError:
                    pass

    def register(self, device_token: str, *, bundle_id: str = "", environment: str = "") -> dict:
        token = _normalize_token(device_token)
        bundle = str(bundle_id or "").strip()
        if bundle and not _BUNDLE_RE.fullmatch(bundle):
            raise ValueError("bundleId is invalid")
        selected_environment = _environment(environment)
        with self._lock:
            payload = self._read()
            payload["devices"][token] = {
                "token": token,
                "bundleId": bundle,
                "environment": selected_environment,
                "updatedAt": utc_now(),
            }
            self._write(payload)
            count = len(payload["devices"])
        return {
            "ok": True,
            "registered": True,
            "device": {
                "tokenSuffix": token[-8:],
                "bundleId": bundle,
                "environment": selected_environment,
            },
            "deviceCount": count,
        }

    def unregister(self, device_token: str) -> dict:
        token = _normalize_token(device_token)
        with self._lock:
            payload = self._read()
            removed = payload["devices"].pop(token, None) is not None
            if removed:
                self._write(payload)
            count = len(payload["devices"])
        return {"ok": True, "unregistered": removed, "deviceCount": count}

    def _devices(self) -> list[dict]:
        with self._lock:
            payload = self._read()
            return [dict(item) for item in payload["devices"].values() if isinstance(item, dict)]

    def configuration(self) -> dict:
        key_id = self.environ.get("HERDR_APNS_KEY_ID", "").strip()
        team_id = self.environ.get("HERDR_APNS_TEAM_ID", "").strip()
        key_path = self.environ.get("HERDR_APNS_KEY_PATH", "").strip()
        topic = self.environ.get("HERDR_APNS_TOPIC", "").strip()
        credentials_present = bool(key_id and team_id and key_path)
        key_found = bool(key_path and Path(key_path).is_file())
        devices = self._devices()
        topics_available = bool(topic or any(item.get("bundleId") for item in devices))
        configured = credentials_present and key_found and topics_available
        reason = None
        if not credentials_present:
            reason = "HERDR_APNS_KEY_ID, HERDR_APNS_TEAM_ID, and HERDR_APNS_KEY_PATH are required"
        elif not key_found:
            reason = "APNs signing key was not found"
        elif not topics_available:
            reason = "HERDR_APNS_TOPIC or a registered bundleId is required"
        return {
            "configured": configured,
            "environment": _environment(self.environ.get("HERDR_APNS_ENV", "")),
            "topicConfigured": bool(topic),
            "deviceCount": len(devices),
            "reason": reason,
        }

    def _auth_token(self) -> tuple[Optional[str], Optional[str]]:
        config = self.configuration()
        if not config["configured"]:
            return None, str(config.get("reason") or "APNs is not configured")
        now = int(time.time())
        with self._lock:
            if self._jwt_token and now - self._jwt_created_at < 50 * 60:
                return self._jwt_token, None
        key_id = self.environ["HERDR_APNS_KEY_ID"].strip()
        team_id = self.environ["HERDR_APNS_TEAM_ID"].strip()
        key_path = self.environ["HERDR_APNS_KEY_PATH"].strip()
        header = _b64url_json({"alg": "ES256", "kid": key_id})
        claims = _b64url_json({"iss": team_id, "iat": now})
        signing_input = f"{header}.{claims}".encode("ascii")
        openssl = shutil.which("openssl")
        if not openssl:
            return None, "openssl is required for APNs token signing"
        try:
            result = subprocess.run(
                [openssl, "dgst", "-sha256", "-sign", key_path],
                input=signing_input,
                capture_output=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return None, f"APNs token signing failed: {exc}"
        if result.returncode != 0:
            error = (result.stderr or b"").decode("utf-8", errors="replace").strip()
            return None, error or "APNs token signing failed"
        try:
            signature = _der_to_raw_signature(result.stdout)
        except ValueError as exc:
            return None, str(exc)
        token = f"{header}.{claims}.{_b64url(signature)}"
        with self._lock:
            self._jwt_token = token
            self._jwt_created_at = now
        return token, None

    def _send(self, device: dict, payload: dict, bearer: str, collapse_id: str) -> tuple[bool, str]:
        token = str(device.get("token") or "")
        topic = self.environ.get("HERDR_APNS_TOPIC", "").strip() or str(device.get("bundleId") or "")
        selected_environment = _environment(self.environ.get("HERDR_APNS_ENV") or device.get("environment"))
        host = "api.push.apple.com" if selected_environment == "production" else "api.sandbox.push.apple.com"
        curl = shutil.which("curl")
        if not curl:
            return False, "curl with HTTP/2 support is required for APNs delivery"
        command = [
            curl,
            "--http2",
            "-sS",
            "-o",
            "-",
            "-w",
            "\n%{http_code}",
            "-X",
            "POST",
            f"https://{host}/3/device/{token}",
            "-H",
            f"authorization: bearer {bearer}",
            "-H",
            f"apns-topic: {topic}",
            "-H",
            "apns-push-type: alert",
            "-H",
            "apns-priority: 10",
            "-H",
            f"apns-collapse-id: {collapse_id[:64]}",
            "--data-binary",
            json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return False, f"APNs send failed: {exc}"
        response_body, _, status_text = (result.stdout or "").rpartition("\n")
        if result.returncode == 0 and status_text.isdigit() and 200 <= int(status_text) < 300:
            return True, ""
        reason = response_body.strip() or (result.stderr or "").strip() or f"HTTP {status_text or result.returncode}"
        return False, f"APNs rejected ...{token[-8:]}: {reason}"

    def notify_alert(self, alert: dict, *, unread_count: int = 1) -> dict:
        devices = self._devices()
        if not devices:
            return {"configured": self.configuration()["configured"], "sent": 0, "errors": ["no registered devices"]}
        bearer, error = self._auth_token()
        if not bearer:
            return {"configured": False, "sent": 0, "errors": [error or "APNs is not configured"]}
        alert_id = str(alert.get("id") or f"herdr-{int(time.time())}")
        payload = {
            "aps": {
                "alert": {
                    "title": str(alert.get("title") or "Herdr agent update")[:120],
                    "body": str(alert.get("message") or "An agent needs attention.")[:700],
                },
                "badge": max(0, int(unread_count)),
                "sound": "default",
                "thread-id": str(alert.get("workspaceId") or "herdr"),
            },
            "event": str(alert.get("kind") or "herdr_agent_alert"),
            "alertId": alert_id,
            "workspaceId": alert.get("workspaceId"),
            "tabId": alert.get("tabId"),
            "paneId": alert.get("paneId"),
            "agentName": alert.get("agentName"),
            "status": alert.get("status"),
        }
        sent = 0
        errors = []
        for device in devices:
            success, send_error = self._send(device, payload, bearer, alert_id)
            if success:
                sent += 1
            elif send_error:
                errors.append(send_error)
        return {"configured": True, "sent": sent, "errors": errors}

    def notify_alert_async(
        self,
        alert: dict,
        *,
        unread_count: int,
        callback: Optional[Callable[[dict], None]] = None,
    ) -> bool:
        alert_id = str(alert.get("id") or "")
        if not alert_id:
            return False
        with self._lock:
            if alert_id in self._delivery_ids:
                return False
            self._delivery_ids.add(alert_id)
            self._delivery_order.append(alert_id)
            while len(self._delivery_order) > 1000:
                expired = self._delivery_order.popleft()
                self._delivery_ids.discard(expired)

        def deliver() -> None:
            result = self.notify_alert(alert, unread_count=unread_count)
            result.update({"alertId": alert_id, "generatedAt": utc_now()})
            if callback:
                callback(result)

        threading.Thread(target=deliver, name=f"herdr-apns-{alert_id[-8:]}", daemon=True).start()
        return True
