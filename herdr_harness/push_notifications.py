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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Mapping, Optional

from .alerts import utc_now


_TOKEN_RE = re.compile(r"^[0-9a-f]{32,256}$")
_BUNDLE_RE = re.compile(r"^[A-Za-z0-9.-]{1,255}$")
_ACTIVITY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$")


@dataclass(frozen=True)
class _APNsSendResult:
    """Detailed APNs response that remains compatible with two-value unpacking."""

    success: bool
    error: str = ""
    status_code: Optional[int] = None
    reason: str = ""

    def __iter__(self):
        yield self.success
        yield self.error

    @property
    def invalidates_live_activity(self) -> bool:
        # ExpiredProviderToken and InvalidProviderToken describe our provider
        # JWT, not the ActivityKit push token, and must never delete a client
        # registration.
        return self.status_code == 410 or self.reason in {
            "BadDeviceToken",
            "DeviceTokenNotForTopic",
            "Unregistered",
        }


@dataclass
class _PulseDelivery:
    content_state: dict
    activity_id: Optional[str]
    timestamp: int
    coalescible: bool
    callbacks: list[Callable[[dict], None]] = field(default_factory=list)


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
        self._jwt_sign_lock = threading.Lock()
        self._jwt_token = ""
        self._jwt_created_at = 0
        self._delivery_ids: set[str] = set()
        self._delivery_order: deque[str] = deque()
        self._pulse_signature: Optional[str] = None
        self._pulse_queue: deque[_PulseDelivery] = deque()
        self._pulse_worker_running = False
        self._pulse_last_timestamp = 0

    def _read(self) -> dict:
        try:
            with self.store_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return {"version": 2, "devices": {}, "liveActivities": {}}
        if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
            return {"version": 2, "devices": {}, "liveActivities": {}}
        if not isinstance(payload.get("liveActivities"), dict):
            payload["liveActivities"] = {}
        payload["version"] = 2
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

    def register_live_activity(
        self,
        push_token: str,
        *,
        activity_id: str,
        bundle_id: str,
        environment: str,
    ) -> dict:
        token = _normalize_token(push_token)
        identifier = str(activity_id or "").strip()
        bundle = str(bundle_id or "").strip()
        if not _ACTIVITY_ID_RE.fullmatch(identifier):
            raise ValueError("activityId is invalid")
        if not _BUNDLE_RE.fullmatch(bundle):
            raise ValueError("bundleId is invalid")
        selected_environment = _environment(environment)
        with self._lock:
            payload = self._read()
            payload["liveActivities"][identifier] = {
                "activityId": identifier,
                "token": token,
                "bundleId": bundle,
                "environment": selected_environment,
                "updatedAt": utc_now(),
            }
            self._write(payload)
            count = len(payload["liveActivities"])
        return {
            "ok": True,
            "registered": True,
            "activity": {
                "activityId": identifier,
                "tokenSuffix": token[-8:],
                "environment": selected_environment,
            },
            "liveActivityCount": count,
        }

    def unregister_live_activity(
        self,
        activity_id: str,
        *,
        push_token: Optional[str] = None,
    ) -> dict:
        identifier = str(activity_id or "").strip()
        if not _ACTIVITY_ID_RE.fullmatch(identifier):
            raise ValueError("activityId is invalid")
        token = _normalize_token(push_token) if push_token else None
        with self._lock:
            payload = self._read()
            existing = payload["liveActivities"].get(identifier)
            removed = bool(
                isinstance(existing, dict)
                and (token is None or existing.get("token") == token)
            )
            if removed:
                payload["liveActivities"].pop(identifier, None)
                self._write(payload)
            count = len(payload["liveActivities"])
        return {
            "ok": True,
            "unregistered": removed,
            "liveActivityCount": count,
        }

    def _devices(self) -> list[dict]:
        with self._lock:
            payload = self._read()
            return [dict(item) for item in payload["devices"].values() if isinstance(item, dict)]

    def _live_activities(self, activity_id: Optional[str] = None) -> list[dict]:
        with self._lock:
            payload = self._read()
            values = payload["liveActivities"].values()
            return [
                dict(item)
                for item in values
                if isinstance(item, dict)
                and (activity_id is None or item.get("activityId") == activity_id)
            ]

    def _prune_live_activity(self, registration: dict) -> bool:
        """Remove a terminal registration only if it still has the sent token."""

        identifier = str(registration.get("activityId") or "")
        token = str(registration.get("token") or "")
        if not identifier or not token:
            return False
        with self._lock:
            payload = self._read()
            current = payload["liveActivities"].get(identifier)
            if not isinstance(current, dict) or current.get("token") != token:
                return False
            payload["liveActivities"].pop(identifier, None)
            self._write(payload)
            return True

    @staticmethod
    def _coerce_live_activity_result(value: object) -> _APNsSendResult:
        if isinstance(value, _APNsSendResult):
            return value
        if not isinstance(value, (tuple, list)) or len(value) != 2:
            return _APNsSendResult(False, "ActivityKit delivery returned an invalid result")
        success, error = value
        return _APNsSendResult(bool(success), str(error or ""))

    def configuration(self) -> dict:
        key_id = self.environ.get("HERDR_APNS_KEY_ID", "").strip()
        team_id = self.environ.get("HERDR_APNS_TEAM_ID", "").strip()
        key_path = self.environ.get("HERDR_APNS_KEY_PATH", "").strip()
        topic = self.environ.get("HERDR_APNS_TOPIC", "").strip()
        credentials_present = bool(key_id and team_id and key_path)
        key_found = bool(key_path and Path(key_path).is_file())
        devices = self._devices()
        live_activities = self._live_activities()
        topics_available = bool(
            topic
            or any(item.get("bundleId") for item in devices)
            or any(item.get("bundleId") for item in live_activities)
        )
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
            "liveActivityCount": len(live_activities),
            "reason": reason,
        }

    def _auth_token(self) -> tuple[Optional[str], Optional[str]]:
        config = self.configuration()
        if not config["configured"]:
            return None, str(config.get("reason") or "APNs is not configured")
        # Signing is intentionally single-flight. A cold start can publish a
        # snapshot, connection event, and per-activity initial state at nearly
        # the same time. Without this gate each caller can miss the empty cache
        # and invoke openssl independently.
        with self._jwt_sign_lock:
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

    def _send_live_activity(
        self,
        registration: dict,
        payload: dict,
        bearer: str,
        priority: int,
    ) -> _APNsSendResult:
        token = str(registration.get("token") or "")
        bundle_id = str(registration.get("bundleId") or "")
        selected_environment = _environment(
            self.environ.get("HERDR_APNS_ENV") or registration.get("environment")
        )
        host = "api.push.apple.com" if selected_environment == "production" else "api.sandbox.push.apple.com"
        curl = shutil.which("curl")
        if not curl:
            return _APNsSendResult(
                False,
                "curl with HTTP/2 support is required for APNs delivery",
            )
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
            f"apns-topic: {bundle_id}.push-type.liveactivity",
            "-H",
            "apns-push-type: liveactivity",
            "-H",
            f"apns-priority: {priority}",
            "--data-binary",
            json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=15, check=False)
        except subprocess.TimeoutExpired:
            # TimeoutExpired stringifies the command, whose URL contains the
            # ActivityKit push token, so do not forward the exception text.
            return _APNsSendResult(False, "ActivityKit send timed out")
        except OSError as exc:
            return _APNsSendResult(
                False,
                f"ActivityKit transport failed ({type(exc).__name__})",
            )
        response_body, _, status_text = (result.stdout or "").rpartition("\n")
        status_text = status_text.strip()
        status_code = int(status_text) if status_text.isdigit() else None
        if result.returncode == 0 and status_code is not None and 200 <= status_code < 300:
            return _APNsSendResult(True, status_code=status_code)

        body = response_body.strip()
        apns_reason = ""
        if body:
            try:
                response_payload = json.loads(body)
            except json.JSONDecodeError:
                response_payload = None
            if isinstance(response_payload, dict):
                candidate = response_payload.get("reason")
                if isinstance(candidate, str):
                    apns_reason = candidate.strip()[:120]
        # Only APNs' structured reason is safe to publish. Curl diagnostics can
        # repeat the request URL, which contains the full push token.
        diagnostic = apns_reason
        if not diagnostic and body:
            diagnostic = "unexpected APNs response"
        elif not diagnostic and (result.stderr or "").strip():
            diagnostic = "curl transport error"
        if status_code is not None:
            status_diagnostic = f"HTTP {status_code}"
            if diagnostic:
                status_diagnostic += f" {diagnostic}"
        else:
            status_diagnostic = diagnostic or f"curl exit {result.returncode}"
        # Never include an ActivityKit push token in an error or callback
        # payload. The activity identifier is sufficient for local diagnosis.
        return _APNsSendResult(
            False,
            f"APNs rejected Live Activity: {status_diagnostic}",
            status_code=status_code,
            reason=apns_reason,
        )

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

    def _deliver_herd_pulse(
        self,
        content_state: dict,
        *,
        activity_id: Optional[str],
        timestamp: int,
    ) -> dict:
        registrations = self._live_activities(activity_id)
        if not registrations:
            return {
                "configured": self.configuration()["configured"],
                "sent": 0,
                "errors": ["no registered Live Activities"],
            }
        bearer, error = self._auth_token()
        if not bearer:
            return {"configured": False, "sent": 0, "errors": [error or "APNs is not configured"]}

        phase = str(content_state.get("phase") or "offline")
        stale_date = timestamp if phase == "offline" else timestamp + 15 * 60
        payload = {
            "aps": {
                "timestamp": timestamp,
                "event": "update",
                "content-state": dict(content_state),
                "stale-date": stale_date,
                "relevance-score": {
                    "attention": 100,
                    "ready": 80,
                    "working": 50,
                    "resting": 20,
                    "offline": 10,
                }.get(phase, 10),
            }
        }
        priority = 10 if phase in {"attention", "ready"} else 5
        sent = 0
        pruned = 0
        errors = []
        for registration in registrations:
            send_result = self._coerce_live_activity_result(
                self._send_live_activity(
                    registration,
                    payload,
                    bearer,
                    priority,
                )
            )
            if send_result.success:
                sent += 1
                continue
            if send_result.invalidates_live_activity and self._prune_live_activity(registration):
                pruned += 1
            if send_result.error:
                errors.append(send_result.error)
        return {"configured": True, "sent": sent, "pruned": pruned, "errors": errors}

    def _reserve_pulse_timestamp_locked(self) -> int:
        timestamp = max(int(time.time()), self._pulse_last_timestamp + 1)
        self._pulse_last_timestamp = timestamp
        return timestamp

    def _enqueue_pulse_locked(
        self,
        content_state: dict,
        *,
        activity_id: Optional[str],
        coalescible: bool,
        callback: Optional[Callable[[dict], None]],
    ) -> tuple[bool, bool]:
        callbacks = [callback] if callback else []
        if coalescible:
            retained: deque[_PulseDelivery] = deque()
            superseded_callbacks: list[Callable[[dict], None]] = []
            for pending in self._pulse_queue:
                if pending.coalescible:
                    superseded_callbacks.extend(pending.callbacks)
                else:
                    retained.append(pending)
            self._pulse_queue = retained
            callbacks = superseded_callbacks + callbacks

        delivery = _PulseDelivery(
            content_state=dict(content_state),
            activity_id=activity_id,
            timestamp=self._reserve_pulse_timestamp_locked(),
            coalescible=coalescible,
            callbacks=callbacks,
        )
        self._pulse_queue.append(delivery)
        should_start = not self._pulse_worker_running
        if should_start:
            self._pulse_worker_running = True
        return True, should_start

    def _start_pulse_worker(self) -> None:
        threading.Thread(
            target=self._pulse_worker,
            name="herdr-pulse-delivery",
            daemon=True,
        ).start()

    def _pulse_worker(self) -> None:
        while True:
            with self._lock:
                if not self._pulse_queue:
                    self._pulse_worker_running = False
                    return
                delivery = self._pulse_queue.popleft()
            try:
                result = self._deliver_herd_pulse(
                    delivery.content_state,
                    activity_id=delivery.activity_id,
                    timestamp=delivery.timestamp,
                )
            except Exception as exc:  # pragma: no cover - defensive worker containment
                result = {
                    "configured": False,
                    "sent": 0,
                    "errors": [f"Live Activity delivery failed ({type(exc).__name__})"],
                }
            result = dict(result)
            result.update({"event": "herd.pulse", "generatedAt": utc_now()})
            for callback in delivery.callbacks:
                try:
                    callback(dict(result))
                except Exception:
                    # A broker or observer callback must not stop later APNs
                    # updates from leaving the ordered worker.
                    continue

    def notify_herd_pulse(
        self,
        content_state: dict,
        *,
        activity_id: Optional[str] = None,
    ) -> dict:
        """Deliver one pulse synchronously while sharing the ordered queue."""

        completed = threading.Event()
        values: list[dict] = []

        def capture(result: dict) -> None:
            values.append(result)
            completed.set()

        with self._lock:
            _, should_start = self._enqueue_pulse_locked(
                content_state,
                activity_id=activity_id,
                coalescible=False,
                callback=capture,
            )
        if should_start:
            self._start_pulse_worker()
        completed.wait()
        return values[0]

    def notify_herd_pulse_async(
        self,
        content_state: dict,
        *,
        force: bool = False,
        activity_id: Optional[str] = None,
        callback: Optional[Callable[[dict], None]] = None,
    ) -> bool:
        signature_state = {
            key: value
            for key, value in content_state.items()
            if key != "updatedAt"
        }
        signature = json.dumps(signature_state, sort_keys=True, separators=(",", ":"))
        with self._lock:
            if not force and signature == self._pulse_signature:
                return False
            if not force:
                self._pulse_signature = signature
            _, should_start = self._enqueue_pulse_locked(
                content_state,
                activity_id=activity_id,
                coalescible=not force and activity_id is None,
                callback=callback,
            )
        if should_start:
            self._start_pulse_worker()
        return True
