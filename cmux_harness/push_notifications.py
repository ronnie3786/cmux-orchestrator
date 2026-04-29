"""Direct APNs support for cmux iOS notifications."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from . import storage

DEVICES_FILE = storage.LOG_DIR / "push-devices.json"
PENDING_FILE = storage.LOG_DIR / "push-pending.json"

_JWT_CACHE: dict[str, object] = {"token": "", "created_at": 0}


def register_device(token: str, bundle_id: str = "", environment: str = "") -> dict:
    token = _normalize_token(token)
    if not token:
        return {"ok": False, "error": "device token required"}

    devices = _read_json(DEVICES_FILE, {})
    devices[token] = {
        "token": token,
        "bundleId": str(bundle_id or "").strip(),
        "environment": _normalize_environment(environment),
        "updatedAt": _now_iso(),
    }
    _write_json(DEVICES_FILE, devices)
    return {"ok": True, "registered": True}


def notify_auto_mode_human_alert(
    *,
    workspace_id: str,
    workspace_uuid: str,
    surface_id: str | None,
    workspace_name: str,
    reason: str,
    request_text: str,
    notification_id: str,
) -> dict:
    notification_id = str(notification_id or "").strip()
    if not notification_id:
        notification_id = f"auto:{workspace_id}"

    pending = _read_json(PENDING_FILE, {})
    if notification_id in pending:
        return {"ok": True, "sent": False, "duplicate": True}

    body = _truncate(request_text or reason or "Approval needed.", 700)
    title = "cmux approval needed"
    payload = {
        "aps": {
            "alert": {
                "title": title,
                "body": body,
            },
            "badge": 1,
            "sound": "default",
        },
        "event": "approval_required",
        "notificationID": notification_id,
        "workspaceID": workspace_id,
        "workspaceUUID": workspace_uuid,
        "surfaceID": surface_id or "",
        "workspaceName": workspace_name,
        "reason": _truncate(reason, 300),
        "request": body,
    }

    pending[notification_id] = {
        "notificationID": notification_id,
        "workspaceID": workspace_id,
        "workspaceUUID": workspace_uuid,
        "surfaceID": surface_id or "",
        "workspaceName": workspace_name,
        "reason": _truncate(reason, 300),
        "request": body,
        "createdAt": _now_iso(),
    }
    _write_json(PENDING_FILE, pending)

    result = _send_to_registered_devices(payload, push_type="alert", priority="10")
    storage.debug_log({
        "event": "push_auto_mode_human_alert",
        "notification_id": notification_id,
        "workspace_id": workspace_id,
        "sent": result.get("sent", 0),
        "errors": result.get("errors", []),
        "configured": result.get("configured", False),
    })
    return {"ok": True, **result}


def clear_workspace_pending(workspace_id: str, workspace_uuid: str = "", surface_id: str = "") -> dict:
    workspace_id = str(workspace_id or "").strip()
    workspace_uuid = str(workspace_uuid or "").strip()
    surface_id = str(surface_id or "").strip()
    pending = _read_json(PENDING_FILE, {})
    cleared_ids = []

    for notification_id, item in list(pending.items()):
        if _matches_workspace(item, workspace_id, workspace_uuid, surface_id):
            cleared_ids.append(notification_id)
            pending.pop(notification_id, None)

    if cleared_ids:
        _write_json(PENDING_FILE, pending)
        _send_to_registered_devices({"aps": {"badge": 0}}, push_type="alert", priority="10")

    return {"ok": True, "cleared": bool(cleared_ids), "clearedIDs": cleared_ids}


def app_workspace_id(workspace_uuid: str, surface_id: str | None = None) -> str:
    workspace_uuid = str(workspace_uuid or "").strip()
    surface_id = str(surface_id or "").strip()
    return f"{workspace_uuid}|{surface_id}" if workspace_uuid and surface_id else workspace_uuid


def approval_request_preview(screen: str, max_chars: int = 700) -> str:
    lines = [line.strip() for line in str(screen or "").splitlines() if line.strip()]
    if not lines:
        return ""
    return _truncate("\n".join(lines[-8:]), max_chars)


def _matches_workspace(item: dict, workspace_id: str, workspace_uuid: str, surface_id: str) -> bool:
    if workspace_id and workspace_id in {
        str(item.get("workspaceID") or ""),
        app_workspace_id(str(item.get("workspaceUUID") or ""), str(item.get("surfaceID") or "")),
    }:
        return True
    if workspace_uuid and str(item.get("workspaceUUID") or "") == workspace_uuid:
        if not surface_id or str(item.get("surfaceID") or "") == surface_id:
            return True
    return False


def _send_to_registered_devices(payload: dict, *, push_type: str, priority: str) -> dict:
    devices = _read_json(DEVICES_FILE, {})
    if not devices:
        return {"configured": False, "sent": 0, "errors": ["no registered APNs devices"]}

    auth = _apns_auth()
    if not auth.get("configured"):
        return {"configured": False, "sent": 0, "errors": [auth.get("error", "APNs is not configured")]}

    sent = 0
    errors = []
    for device in devices.values():
        token = device.get("token") or ""
        topic = os.environ.get("CMUX_APNS_TOPIC", "").strip() or device.get("bundleId") or ""
        if not token or not topic:
            errors.append("device token or APNs topic missing")
            continue
        environment = _normalize_environment(os.environ.get("CMUX_APNS_ENV", "") or device.get("environment", ""))
        ok, error = _send_apns_payload(
            token=token,
            topic=topic,
            environment=environment,
            bearer=auth["token"],
            payload=payload,
            push_type=push_type,
            priority=priority,
        )
        if ok:
            sent += 1
        elif error:
            errors.append(error)
    return {"configured": True, "sent": sent, "errors": errors}


def _apns_auth() -> dict:
    key_id = os.environ.get("CMUX_APNS_KEY_ID", "").strip()
    team_id = os.environ.get("CMUX_APNS_TEAM_ID", "").strip()
    key_path = os.environ.get("CMUX_APNS_KEY_PATH", "").strip()
    if not key_id or not team_id or not key_path:
        return {"configured": False, "error": "CMUX_APNS_KEY_ID, CMUX_APNS_TEAM_ID, and CMUX_APNS_KEY_PATH are required"}
    if not Path(key_path).exists():
        return {"configured": False, "error": f"APNs key file not found: {key_path}"}

    created_at = int(_JWT_CACHE.get("created_at") or 0)
    cached = str(_JWT_CACHE.get("token") or "")
    now = int(time.time())
    if cached and now - created_at < 50 * 60:
        return {"configured": True, "token": cached}

    header = _b64url_json({"alg": "ES256", "kid": key_id})
    claims = _b64url_json({"iss": team_id, "iat": now})
    signing_input = f"{header}.{claims}".encode("ascii")
    try:
        signature = _sign_es256(signing_input, key_path)
    except Exception as exc:
        return {"configured": False, "error": f"APNs token signing failed: {exc}"}
    token = f"{header}.{claims}.{_b64url(signature)}"
    _JWT_CACHE["token"] = token
    _JWT_CACHE["created_at"] = now
    return {"configured": True, "token": token}


def _send_apns_payload(
    *,
    token: str,
    topic: str,
    environment: str,
    bearer: str,
    payload: dict,
    push_type: str,
    priority: str,
) -> tuple[bool, str]:
    host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
    url = f"https://{host}/3/device/{token}"
    cmd = [
        "curl",
        "--http2",
        "-sS",
        "-o",
        "-",
        "-w",
        "\n%{http_code}",
        "-X",
        "POST",
        url,
        "-H",
        f"authorization: bearer {bearer}",
        "-H",
        f"apns-topic: {topic}",
        "-H",
        f"apns-push-type: {push_type}",
        "-H",
        f"apns-priority: {priority}",
        "-d",
        json.dumps(payload, separators=(",", ":")),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"APNs send failed: {exc}"

    output = result.stdout or ""
    body, _, status = output.rpartition("\n")
    if result.returncode == 0 and status.isdigit() and 200 <= int(status) < 300:
        return True, ""
    error = body.strip() or (result.stderr or "").strip() or f"HTTP {status or result.returncode}"
    return False, f"APNs rejected {token[:8]}...: {error}"


def _sign_es256(signing_input: bytes, key_path: str) -> bytes:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        capture_output=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or b"openssl signing failed").decode("utf-8", errors="replace"))
    return _der_ecdsa_to_raw(result.stdout)


def _der_ecdsa_to_raw(der: bytes) -> bytes:
    offset = 0
    if der[offset] != 0x30:
        raise ValueError("invalid ECDSA signature")
    offset += 1
    _, offset = _read_der_length(der, offset)
    r, offset = _read_der_integer(der, offset)
    s, _ = _read_der_integer(der, offset)
    return r[-32:].rjust(32, b"\x00") + s[-32:].rjust(32, b"\x00")


def _read_der_length(der: bytes, offset: int) -> tuple[int, int]:
    first = der[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    value = int.from_bytes(der[offset:offset + count], "big")
    return value, offset + count


def _read_der_integer(der: bytes, offset: int) -> tuple[bytes, int]:
    if der[offset] != 0x02:
        raise ValueError("invalid ECDSA integer")
    offset += 1
    length, offset = _read_der_length(der, offset)
    value = der[offset:offset + length].lstrip(b"\x00")
    return value, offset + length


def _b64url_json(value: dict) -> str:
    return _b64url(json.dumps(value, separators=(",", ":")).encode("utf-8"))


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _normalize_token(token: str) -> str:
    return "".join(ch for ch in str(token or "").strip().lower() if ch in "0123456789abcdef")


def _normalize_environment(environment: str) -> str:
    value = str(environment or "").strip().lower()
    return "production" if value == "production" else "sandbox"


def _truncate(value: str, limit: int) -> str:
    value = str(value or "").strip()
    if len(value) <= limit:
        return value
    return value[: max(0, limit - 1)].rstrip() + "..."


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_json(path: Path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            value = json.load(f)
        return value if isinstance(value, type(fallback)) else fallback
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return fallback


def _write_json(path: Path, value) -> None:
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(value, f, indent=2)
    except OSError as exc:
        storage.debug_log({"event": "push_write_error", "path": str(path), "error": str(exc)})
