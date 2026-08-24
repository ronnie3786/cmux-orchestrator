"""Standard-library HTTP and SSE server for Herdr Harness."""

from __future__ import annotations

import errno
import hmac
import html
import json
import os
import re
import socketserver
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional

from . import attachments, voice
from .alerts import utc_now
from .client import HerdrAPIError, HerdrClientError
from .cleanup import CleanupError
from .network import public_base_url
from .pi_semantic import PI_SEMANTIC_PROTOCOL, PiSemanticError
from .service import HerdrService, _find_pane_id
from .terminal import TerminalObserverError
from .workspace_tools import WorkspaceToolError


MAX_BODY_BYTES = 1024 * 1024
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$")
_RUN_ID_RE = re.compile(r"^clr_[0-9a-f]{12}$")
_AGENT_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
_KEY_RE = re.compile(r"^[A-Za-z0-9+_-]{1,32}$")
_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
_EVENT_NAME_RE = re.compile(r"[^A-Za-z0-9_.-]")
_AGENT_STATUSES = frozenset({"idle", "working", "blocked", "done", "unknown"})
_AGENT_KINDS = frozenset(
    {
        "pi",
        "claude",
        "codex",
        "gemini",
        "cursor",
        "devin",
        "agy",
        "cline",
        "omp",
        "mastracode",
        "opencode",
        "copilot",
        "kimi",
        "kiro",
        "droid",
        "amp",
        "grok",
        "hermes",
        "kilo",
        "qodercli",
        "maki",
    }
)

_DISCONNECT_ERRNOS = {errno.EBADF, errno.ECONNABORTED, errno.ECONNRESET, errno.EPIPE}

_HERDR_WEB_STATIC = os.path.join(os.path.dirname(__file__), "static", "herdr-web")
_HERDR_WEB_CONTENT_TYPES = {
    ".html": "text/html",
    ".js": "text/javascript",
    ".css": "text/css",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".json": "application/json",
}


SETUP_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Herdr Harness</title>
<style>
:root{color-scheme:dark;--ink:#f7f7f5;--muted:#9b9b96;--line:#292927;--panel:#181817;--green:#70e0a2}
*{box-sizing:border-box}body{margin:0;background:#0d0d0c;color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
main{width:min(760px,calc(100% - 36px));margin:9vh auto}.mark{width:44px;height:44px;border-radius:13px;display:grid;place-items:center;background:var(--ink);color:#111;font-weight:800;font-size:22px}
h1{font-size:42px;letter-spacing:-1.7px;line-height:1.05;margin:24px 0 10px}p{color:var(--muted);font-size:17px}.card{margin-top:30px;padding:22px;border:1px solid var(--line);background:var(--panel);border-radius:18px;box-shadow:0 20px 70px #0005}
.row{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--line)}.row:last-child{border:0}.status{display:flex;align-items:center;gap:9px}.dot{width:9px;height:9px;border-radius:50%;background:#777}.dot.live{background:var(--green);box-shadow:0 0 16px #70e0a280}code{font-family:"SF Mono",ui-monospace,monospace;color:#d7d7d2;font-size:13px}
input,button{border:1px solid #373735;background:#222220;color:var(--ink);border-radius:10px;padding:10px 12px;font:inherit}input{width:100%}button{cursor:pointer;font-weight:650}button:hover{background:#2b2b28}.token{display:flex;gap:8px;margin-top:15px}.fine{font-size:13px;margin-top:18px}
</style>
</head>
<body><main><div class="mark">H</div><h1>Your agents, within reach.</h1>
<p>Herdr Harness is listening on this Mac. Connect the iOS app using a local or Tailscale address, then move through workspaces, panes, and live agent sessions.</p>
<section class="card"><div class="row"><strong>Backend</strong><span class="status"><i class="dot" id="dot"></i><span id="state">Checking</span></span></div>
<div class="row"><span>API base</span><code>/api/v1</code></div><div class="row"><span>Live events</span><code>/api/v1/events</code></div><div class="row"><span>Default port</span><code>9092</code></div>
	<div class="token"><input id="token" type="password" autocomplete="new-password" placeholder="Bearer token"><button id="check">Check</button><button id="clear">Clear</button></div>
	<p class="fine">For private remote access, first configure an API token, then run <code>tailscale serve --bg --https=8461 9092</code>. Use <code>https://&lt;machine&gt;.&lt;tailnet&gt;.ts.net:8461</code> in the iOS app. This dedicated port preserves existing Serve handlers.</p></section></main>
	<script>
	const token=document.querySelector('#token'),state=document.querySelector('#state'),dot=document.querySelector('#dot');
	async function check(){try{const headers=token.value?{Authorization:`Bearer ${token.value}`}:{},r=await fetch('/api/v1/health',{headers}),j=await r.json();if(!r.ok)throw Error(j.error?.message||r.statusText);state.textContent=j.herdr?.connected?'Connected to Herdr':(j.cache?.available?'Cached snapshot, reconnecting':'Herdr unavailable');dot.classList.toggle('live',!!j.herdr?.connected)}catch(e){state.textContent=e.message;dot.classList.remove('live')}}
	document.querySelector('#check').onclick=check;document.querySelector('#clear').onclick=()=>{token.value='';token.focus()};check();
</script></body></html>"""


class HTTPValidationError(ValueError):
    def __init__(self, message: str, *, code: str = "invalid_request", status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = status


def _identifier(value: Any, label: str = "identifier") -> str:
    text = str(value or "")
    if not _IDENTIFIER_RE.fullmatch(text):
        raise HTTPValidationError(f"{label} is invalid")
    return text


def _run_id(value: Any) -> str:
    text = str(value or "")
    if not _RUN_ID_RE.fullmatch(text):
        raise HTTPValidationError("Run not found", code="not_found", status=404)
    return text


def _string(
    value: Any,
    label: str,
    *,
    maximum: int,
    allow_empty: bool = False,
) -> str:
    if not isinstance(value, str):
        raise HTTPValidationError(f"{label} must be a string")
    if "\x00" in value:
        raise HTTPValidationError(f"{label} contains a null byte")
    text = value.strip() if label in {"label", "name", "kind"} else value
    if not allow_empty and not text:
        raise HTTPValidationError(f"{label} is required")
    if len(text) > maximum:
        raise HTTPValidationError(f"{label} exceeds {maximum} characters")
    return text


def _optional_cwd(body: dict) -> Optional[str]:
    if "cwd" not in body or body.get("cwd") is None:
        return None
    cwd = _string(body.get("cwd"), "cwd", maximum=4096)
    expanded = os.path.abspath(os.path.expanduser(cwd))
    if not os.path.isabs(cwd):
        raise HTTPValidationError("cwd must be an absolute path")
    if not os.path.isdir(expanded):
        raise HTTPValidationError("cwd must be an existing directory")
    return expanded


def _optional_env(body: dict) -> dict[str, str]:
    value = body.get("env", {})
    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > 64:
        raise HTTPValidationError("env must be an object with at most 64 entries")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not _ENV_KEY_RE.fullmatch(key):
            raise HTTPValidationError("env contains an invalid variable name")
        if not isinstance(item, str) or "\x00" in item or len(item) > 8192:
            raise HTTPValidationError(f"env value for {key} is invalid")
        result[key] = item
    return result


def _boolean(value: Any, label: str, *, default: bool = False) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise HTTPValidationError(f"{label} must be a boolean")
    return value


def _query_bool(query: dict[str, list[str]], key: str, default: bool = False) -> bool:
    raw = (query.get(key) or [None])[0]
    if raw is None:
        return default
    value = str(raw).lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise HTTPValidationError(f"{key} must be true or false")


def _query_int(
    query: dict[str, list[str]],
    key: str,
    default: int,
    *,
    minimum: int,
    maximum: int,
) -> int:
    raw = (query.get(key) or [str(default)])[0]
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise HTTPValidationError(f"{key} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise HTTPValidationError(f"{key} must be between {minimum} and {maximum}")
    return value


def _herdr_status(exc: HerdrClientError) -> int:
    code = str(getattr(exc, "code", ""))
    if code in {"herdr_unavailable", "herdr_disconnected"}:
        return 503
    if "timeout" in code:
        return 504
    if code.endswith("not_found") or code in {"not_found", "pane_not_found", "workspace_not_found", "tab_not_found"}:
        return 404
    if "conflict" in code or "busy" in code:
        return 409
    if code.startswith("invalid_") or code.endswith("_invalid"):
        return 400
    return 502


def api_description() -> dict:
    return {
        "ok": True,
        "service": "herdr-harness",
        "version": 1,
        "endpoints": {
            "health": "/api/v1/health",
            "network": "/api/v1/network",
            "snapshot": "/api/v1/snapshot",
            "workspaces": "/api/v1/workspaces",
            "workspace": "/api/v1/workspaces/{workspaceId}",
            "workspaceGit": "/api/v1/workspaces/{workspaceId}/git",
            "workspaceSkills": "/api/v1/workspaces/{workspaceId}/skills",
            "workspaceFiles": "/api/v1/workspaces/{workspaceId}/files",
            "jiraAssigned": "/api/v1/jira/assigned",
            "voiceTranscriptions": "/api/v1/voice/transcriptions",
            "events": "/api/v1/events",
            "paneOutput": "/api/v1/panes/{paneId}/output",
            "paneStream": "/api/v1/panes/{paneId}/stream",
            "paneStar": "/api/v1/panes/{paneId}/star",
            "piSnapshot": "/api/v1/panes/{paneId}/pi/snapshot",
            "piEvents": "/api/v1/panes/{paneId}/pi/events",
            "piModels": "/api/v1/panes/{paneId}/pi/models",
            "piThinkingLevel": "/api/v1/panes/{paneId}/pi/thinking-level",
            "alerts": "/api/v1/alerts",
            "pushStatus": "/api/v1/push/status",
            "liveActivities": "/api/v1/live-activities",
            "paneLink": "/api/v1/panes/{paneId}/link",
            "cleanupRuns": "/api/v1/cleanup/runs",
            "cleanupRun": "/api/v1/cleanup/runs/{runId}",
            "cleanupModels": "/api/v1/cleanup/models",
        },
        "universalLinks": {
            "appSiteAssociation": "/.well-known/apple-app-site-association",
            "openPane": "/open/pane/{paneId}",
            "customScheme": "herdr://pane/{paneId}",
        },
        "mutations": [
            "POST /api/v1/workspaces",
            "PATCH|DELETE /api/v1/workspaces/{workspaceId}",
            "POST /api/v1/workspaces/{workspaceId}/focus|tabs",
            "POST /api/v1/workspaces/{workspaceId}/git/stage|git/unstage|attachments",
            "PATCH|DELETE /api/v1/tabs/{tabId}",
            "POST /api/v1/tabs/{tabId}/focus",
            "PATCH|DELETE /api/v1/panes/{paneId}",
            "POST /api/v1/panes/{paneId}/focus|zoom|split|send-text|send-keys|run|prompt|start-agent",
            "POST /api/v1/panes/{paneId}/star",
            "POST /api/v1/panes/{paneId}/pi/prompt|steer|follow-up|abort|model|thinking-level",
            "POST /api/v1/panes/{paneId}/pi/interactions/{interactionId}/respond",
            "POST /api/v1/alerts/{alertId}/read",
            "POST /api/v1/alerts/read-all",
            "POST /api/v1/push/devices|unregister",
            "POST /api/v1/live-activities|unregister",
            "POST /api/v1/voice/transcriptions",
            "POST /api/v1/quick-sessions/pi",
            "POST /api/v1/cleanup/runs",
            "POST /api/v1/cleanup/runs/{runId}/apply",
            "POST /api/v1/cleanup/runs/{runId}/cancel",
        ],
        "sseEvents": [
            "snapshot.updated",
            "alert.created",
            "alert.updated",
            "alerts.read_state_changed",
            "stars.changed",
            "cleanup.run_updated",
        ],
        "generatedAt": utc_now(),
    }


DEFAULT_UNIVERSAL_LINK_APP_IDS = "L2M32HMQZH.dev.ronnierocha.herdr-harness.herdr-harness-ios"


def _universal_link_app_ids(environ) -> list[str]:
    raw = environ.get("HERDR_HARNESS_APP_IDS", "") or DEFAULT_UNIVERSAL_LINK_APP_IDS
    return [item.strip() for item in raw.split(",") if item.strip()]


def _open_pane_page(pane_id: str) -> str:
    """Fallback page served when a universal link opens in a browser."""
    scheme_link = "herdr://pane/" + urllib.parse.quote(pane_id, safe="")
    escaped_link = html.escape(scheme_link, quote=True)
    escaped_id = html.escape(pane_id)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Open in Herdr</title>
<style>body{{background:#1e1e2e;color:#cdd6f4;font:16px/1.5 ui-monospace,Menlo,monospace;display:grid;place-items:center;min-height:100vh;margin:0}}main{{text-align:center;padding:24px}}a.button{{display:inline-block;margin-top:16px;padding:12px 20px;border-radius:12px;background:#89b4fa;color:#11111b;text-decoration:none;font-weight:650}}p.fine{{font-size:13px;color:#7f849c;margin-top:18px}}</style></head>
<body><main><h1>Open in Herdr</h1>
<p>pane <code>{escaped_id}</code></p>
<a class="button" href="{escaped_link}">Open the app</a>
<p class="fine">If nothing happens, install the Herdr Harness app on this device.</p>
</main><script>window.location.href={json.dumps(scheme_link)};</script></body></html>"""


def make_handler(service: HerdrService, *, api_token: Optional[str] = None):
    """Create a request handler bound to one HerdrService."""

    configured_token = api_token if api_token is not None else service.environ.get("HERDR_HARNESS_API_TOKEN", "")
    cors_origin = service.environ.get("HERDR_HARNESS_CORS_ORIGIN", "")
    universal_app_ids = _universal_link_app_ids(service.environ)

    class HerdrHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: Any) -> None:
            if service.environ.get("HERDR_HARNESS_HTTP_LOG") in {"1", "true", "yes"}:
                super().log_message(fmt, *args)

        def _common_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if cors_origin:
                self.send_header("Access-Control-Allow-Origin", cors_origin)
                self.send_header("Vary", "Origin")

        def _json_response(self, data: dict, status: int = 200) -> None:
            body = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self._common_headers()
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                return

        def _error(self, status: int, code: str, message: str) -> None:
            self._json_response(
                {"ok": False, "error": {"code": code, "message": message}, "generatedAt": utc_now()},
                status,
            )

        def _authorized(self) -> bool:
            if not configured_token:
                return True
            authorization = self.headers.get("Authorization", "")
            scheme, separator, candidate = authorization.partition(" ")
            valid = separator and scheme.lower() == "bearer" and hmac.compare_digest(candidate, configured_token)
            if not valid:
                self.send_response(401)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                body = json.dumps(
                    {"ok": False, "error": {"code": "unauthorized", "message": "A valid bearer token is required"}}
                ).encode("utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("WWW-Authenticate", 'Bearer realm="Herdr Harness"')
                self._common_headers()
                self.end_headers()
                self.wfile.write(body)
                return False
            return True

        def _read_json(self, *, maximum: int = MAX_BODY_BYTES) -> dict:
            raw_length = self.headers.get("Content-Length", "0")
            try:
                length = int(raw_length)
            except ValueError as exc:
                raise HTTPValidationError("Content-Length is invalid") from exc
            if length < 0 or length > maximum:
                limit_mb = maximum // (1024 * 1024)
                raise HTTPValidationError(
                    f"request body exceeds {limit_mb} MB",
                    code="body_too_large",
                    status=413,
                )
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                value = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise HTTPValidationError("request body must be valid JSON") from exc
            if not isinstance(value, dict):
                raise HTTPValidationError("request body must be a JSON object")
            return value

        def _parse(self) -> tuple[str, list[str], dict[str, list[str]]]:
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            segments = [urllib.parse.unquote(item) for item in path.split("/") if item]
            return path, segments, urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

        def _dispatch(self, method: str) -> None:
            try:
                path, segments, query = self._parse()
                if method == "GET" and path == "/":
                    body = SETUP_HTML.encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self._common_headers()
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if method == "GET" and path in {
                    "/.well-known/apple-app-site-association",
                    "/apple-app-site-association",
                }:
                    # Served without auth: iOS fetches this anonymously when
                    # validating associated domains (mode=developer).
                    self._json_response(
                        {
                            "applinks": {
                                "details": [
                                    {
                                        "appIDs": universal_app_ids,
                                        "components": [{"/": "/open/*"}],
                                    }
                                ]
                            }
                        }
                    )
                    return
                if segments[:1] == ["open"]:
                    if (
                        method == "GET"
                        and len(segments) == 3
                        and segments[1] == "pane"
                        and _IDENTIFIER_RE.fullmatch(segments[2])
                    ):
                        body = _open_pane_page(segments[2]).encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/html; charset=utf-8")
                        self.send_header("Content-Length", str(len(body)))
                        self._common_headers()
                        self.end_headers()
                        self.wfile.write(body)
                    else:
                        self._error(404, "not_found", "Unknown link")
                    return
                if method == "GET" and self._serve_herdr_web_static(path):
                    return
                if len(segments) < 2 or segments[:2] != ["api", "v1"]:
                    self._error(404, "not_found", "Endpoint not found")
                    return
                if (
                    method in {"POST", "DELETE"}
                    and (
                        path.startswith("/api/v1/push/")
                        or path.startswith("/api/v1/live-activities")
                    )
                    and not configured_token
                ):
                    self._error(
                        503,
                        "api_token_required",
                        "Configure HERDR_HARNESS_API_TOKEN before managing push devices",
                    )
                    return
                if not self._authorized():
                    return
                attachment_upload = (
                    method == "POST"
                    and len(segments) == 5
                    and segments[:3] == ["api", "v1", "workspaces"]
                    and segments[4] == "attachments"
                )
                voice_upload = method == "POST" and segments[2:] == ["voice", "transcriptions"]
                if attachment_upload:
                    maximum = attachments.MAX_ATTACHMENT_JSON_BYTES
                elif voice_upload:
                    maximum = voice.MAX_VOICE_JSON_BYTES
                else:
                    maximum = MAX_BODY_BYTES
                body = self._read_json(maximum=maximum) if method in {"POST", "PATCH", "DELETE"} else {}
                response = self._route(method, segments, query, body)
                if response is not None:
                    if isinstance(response, tuple):
                        payload, status = response
                        self._json_response(payload, status)
                    else:
                        self._json_response(response)
            except HTTPValidationError as exc:
                self._error(exc.status, exc.code, str(exc))
            except HerdrAPIError as exc:
                self._error(_herdr_status(exc), exc.code, str(exc))
            except HerdrClientError as exc:
                self._error(_herdr_status(exc), exc.code, str(exc))
            except TerminalObserverError as exc:
                self._error(503, "terminal_observer_unavailable", str(exc))
            except PiSemanticError as exc:
                self._error(exc.status, exc.code, str(exc))
            except CleanupError as exc:
                self._error(exc.status, exc.code, str(exc))
            except WorkspaceToolError as exc:
                self._error(exc.status, exc.code, str(exc))
            except attachments.AttachmentError as exc:
                self._error(exc.status, exc.code, str(exc))
            except voice.VoiceError as exc:
                self._error(exc.status, exc.code, str(exc))
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                return
            except Exception:
                self._error(500, "internal_error", "The harness could not complete this request")
                if service.environ.get("HERDR_HARNESS_HTTP_LOG") in {"1", "true", "yes"}:
                    raise

        def _serve_herdr_web_static(self, path: str) -> bool:
            if path == "/herdr-web":
                target = os.path.join(_HERDR_WEB_STATIC, "index.html")
            elif path.startswith("/herdr-web/"):
                relative = path[len("/herdr-web/"):].strip("/")
                if not relative:
                    target = os.path.join(_HERDR_WEB_STATIC, "index.html")
                else:
                    resolved = os.path.normpath(os.path.join(_HERDR_WEB_STATIC, relative))
                    try:
                        if os.path.commonpath([_HERDR_WEB_STATIC, resolved]) != _HERDR_WEB_STATIC:
                            return False
                    except ValueError:
                        return False
                    target = resolved
            else:
                return False
            if not os.path.isfile(target):
                return False
            content_type = _HERDR_WEB_CONTENT_TYPES.get(
                os.path.splitext(target)[1].lower(), "application/octet-stream"
            )
            with open(target, "rb") as handle:
                body = handle.read()
            try:
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self._common_headers()
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                return False
            return True

        def _route(
            self,
            method: str,
            segments: list[str],
            query: dict[str, list[str]],
            body: dict,
        ) -> Optional[dict | tuple[dict, int]]:
            # segments starts with api, v1.
            tail = segments[2:]
            if method == "GET" and not tail:
                return api_description()
            if method == "GET" and tail == ["health"]:
                return service.health_response()
            if method == "GET" and tail == ["network"]:
                port = int(self.server.server_address[1])
                return service.network_response(port, host_header=self.headers.get("Host", ""))
            if method == "GET" and tail == ["snapshot"]:
                return service.snapshot_response()
            if method == "GET" and tail == ["workspaces"]:
                return service.workspaces_response()
            if method == "GET" and len(tail) == 2 and tail[0] == "workspaces":
                workspace_id = _identifier(tail[1], "workspace ID")
                result = service.workspace_response(workspace_id)
                if result is None:
                    raise HTTPValidationError("Workspace not found", code="not_found", status=404)
                return result
            if len(tail) >= 3 and tail[0] == "workspaces":
                workspace_id = _identifier(tail[1], "workspace ID")
                if method == "GET" and len(tail) == 3 and tail[2] == "git":
                    return service.workspace_git_status(workspace_id)
                if method == "GET" and len(tail) == 4 and tail[2:] == ["git", "diff"]:
                    file = _string((query.get("file") or [""])[0], "file", maximum=4096)
                    section = str((query.get("section") or ["unstaged"])[0])
                    return service.workspace_git_diff(workspace_id, file=file, section=section)
                if method == "POST" and len(tail) == 4 and tail[2] == "git":
                    file = _string(body.get("file"), "file", maximum=4096)
                    if tail[3] == "stage":
                        return service.workspace_git_stage(workspace_id, file=file)
                    if tail[3] == "unstage":
                        return service.workspace_git_unstage(workspace_id, file=file)
                if method == "GET" and len(tail) == 3 and tail[2] == "skills":
                    return service.workspace_skills(workspace_id)
                if method == "GET" and len(tail) == 3 and tail[2] == "files":
                    raw_query = (query.get("q") or query.get("query") or [""])[0]
                    search_query = _string(
                        raw_query,
                        "query",
                        maximum=512,
                        allow_empty=True,
                    )
                    limit = _query_int(query, "limit", 80, minimum=1, maximum=500)
                    return service.workspace_file_search(
                        workspace_id,
                        query=search_query,
                        limit=limit,
                    )
                if method == "POST" and len(tail) == 3 and tail[2] == "attachments":
                    filename = _string(body.get("filename"), "filename", maximum=512)
                    content_type = _string(
                        body.get("content_type") or "application/octet-stream",
                        "content_type",
                        maximum=255,
                    )
                    data_base64 = body.get("data_base64")
                    if not isinstance(data_base64, str):
                        raise HTTPValidationError("data_base64 must be a string")
                    return service.workspace_attachment(
                        workspace_id,
                        filename=filename,
                        content_type=content_type,
                        data_base64=data_base64,
                    )
            if method == "GET" and tail == ["jira", "assigned"]:
                project = str((query.get("project") or [""])[0]).strip()
                limit = _query_int(query, "limit", 50, minimum=1, maximum=100)
                return service.jira_assigned(project=project, limit=limit)
            if method == "GET" and tail == ["jira", "issue"]:
                issue_query = str((query.get("q") or query.get("key") or [""])[0]).strip()
                if len(issue_query) > 2048 or "\x00" in issue_query:
                    raise HTTPValidationError("Jira query is invalid")
                return service.jira_issue(query=issue_query)
            if method == "POST" and tail == ["voice", "transcriptions"]:
                filename = _string(body.get("filename"), "filename", maximum=128)
                mime_type = _string(
                    body.get("mime_type") or "audio/wav",
                    "mime_type",
                    maximum=64,
                )
                data_base64 = body.get("data_base64")
                if not isinstance(data_base64, str):
                    raise HTTPValidationError("data_base64 must be a string")
                return service.transcribe_voice(
                    filename=filename,
                    mime_type=mime_type,
                    data_base64=data_base64,
                )
            if method == "GET" and tail == ["events"]:
                self._serve_events(query)
                return None
            if method == "GET" and len(tail) == 4 and tail[0] == "panes" and tail[2:] == ["pi", "snapshot"]:
                return service.pi_snapshot_response(_identifier(tail[1], "pane ID"))
            if method == "GET" and len(tail) == 4 and tail[0] == "panes" and tail[2:] == ["pi", "events"]:
                self._serve_pi_events(_identifier(tail[1], "pane ID"), query)
                return None
            if method == "GET" and len(tail) == 4 and tail[0] == "panes" and tail[2:] == ["pi", "models"]:
                return service.pi_command(_identifier(tail[1], "pane ID"), "list_models", {})
            if method == "GET" and tail == ["alerts"]:
                unread = _query_bool(query, "unread", False)
                limit = _query_int(query, "limit", 100, minimum=1, maximum=500)
                status = (query.get("status") or [None])[0]
                if status is not None and status not in {"blocked", "done"}:
                    raise HTTPValidationError("status must be blocked or done")
                return service.list_alerts(unread_only=unread, status=status, limit=limit)
            if method == "POST" and tail == ["cleanup", "runs"]:
                options: dict[str, Any] = {}
                if "model" in body:
                    options["model"] = _string(body.get("model"), "model", maximum=256)
                if "thinkingLevel" in body:
                    options["thinkingLevel"] = _string(body.get("thinkingLevel"), "thinkingLevel", maximum=32)
                if "costThresholdUSD" in body:
                    value = body.get("costThresholdUSD")
                    if not isinstance(value, (int, float)) or isinstance(value, bool):
                        raise HTTPValidationError("costThresholdUSD must be a number")
                    options["costThresholdUSD"] = float(value)
                if "tailLines" in body:
                    value = body.get("tailLines")
                    if not isinstance(value, int) or isinstance(value, bool):
                        raise HTTPValidationError("tailLines must be an integer")
                    options["tailLines"] = value
                if "keepEvidence" in body:
                    options["keepEvidence"] = _boolean(body.get("keepEvidence"), "keepEvidence")
                if "workspaceIds" in body:
                    raw_ids = body.get("workspaceIds")
                    if not isinstance(raw_ids, list) or len(raw_ids) > 200:
                        raise HTTPValidationError("workspaceIds must be an array with at most 200 entries")
                    options["workspaceIds"] = [_identifier(item, "workspace ID") for item in raw_ids]
                return service.cleanup.start_run(options), 202
            if method == "GET" and tail == ["cleanup", "runs"]:
                return service.cleanup.list_runs(_query_int(query, "limit", 10, minimum=1, maximum=100))
            if method == "GET" and len(tail) == 3 and tail[:2] == ["cleanup", "runs"]:
                return service.cleanup.get_run(_run_id(tail[2]))
            if method == "POST" and len(tail) == 4 and tail[:2] == ["cleanup", "runs"] and tail[3] == "apply":
                pane_values, workspace_values = body.get("paneIds", []), body.get("workspaceIds", [])
                if not isinstance(pane_values, list) or len(pane_values) > 500:
                    raise HTTPValidationError("paneIds must be an array with at most 500 entries")
                if not isinstance(workspace_values, list) or len(workspace_values) > 200:
                    raise HTTPValidationError("workspaceIds must be an array with at most 200 entries")
                return service.cleanup.apply_run(_run_id(tail[2]), [_identifier(item, "pane ID") for item in pane_values], [_identifier(item, "workspace ID") for item in workspace_values])
            if method == "POST" and len(tail) == 4 and tail[:2] == ["cleanup", "runs"] and tail[3] == "cancel":
                return service.cleanup.cancel_run(_run_id(tail[2]))
            if method == "GET" and tail == ["cleanup", "models"]:
                return service.cleanup.list_models()
            if method == "GET" and tail == ["push", "status"]:
                return service.push_status()
            if method == "GET" and len(tail) == 3 and tail[0] == "panes" and tail[2] == "link":
                pane_id = _identifier(tail[1], "pane ID")
                encoded = urllib.parse.quote(pane_id, safe="")
                base_url, source = public_base_url(
                    service.environ,
                    host_header=self.headers.get("Host", ""),
                    forwarded_proto=self.headers.get("X-Forwarded-Proto", ""),
                )
                response: dict[str, Any] = {
                    "ok": True,
                    "paneId": pane_id,
                    "customSchemeLink": f"herdr://pane/{encoded}",
                }
                if base_url:
                    response["universalLink"] = f"{base_url}/open/pane/{encoded}"
                    response["baseUrl"] = base_url
                    response["baseUrlSource"] = source
                return response
            if method == "GET" and len(tail) == 3 and tail[0] == "panes" and tail[2] == "output":
                pane_id = _identifier(tail[1], "pane ID")
                source = (query.get("source") or ["recent_unwrapped"])[0].replace("-", "_")
                if source not in {"visible", "recent", "recent_unwrapped", "detection"}:
                    raise HTTPValidationError("source is invalid")
                format_name = (query.get("format") or ["text"])[0]
                if format_name not in {"text", "ansi"}:
                    raise HTTPValidationError("format must be text or ansi")
                lines = _query_int(query, "lines", 240, minimum=1, maximum=5000)
                strip_ansi = _query_bool(query, "stripAnsi", format_name == "text")
                return service.read_pane(
                    pane_id,
                    source=source,
                    lines=lines,
                    format_name=format_name,
                    strip_ansi=strip_ansi,
                )
            if method == "GET" and len(tail) == 3 and tail[0] == "panes" and tail[2] == "stream":
                pane_id = _identifier(tail[1], "pane ID")
                cols = _query_int(query, "cols", 100, minimum=20, maximum=300)
                rows = _query_int(query, "rows", 32, minimum=8, maximum=160)
                self._serve_terminal_stream(pane_id, cols=cols, rows=rows)
                return None
            if method == "POST" and tail == ["workspaces"]:
                params: dict[str, Any] = {
                    "focus": _boolean(body.get("focus"), "focus", default=True),
                    "env": _optional_env(body),
                }
                cwd = _optional_cwd(body)
                if cwd is not None:
                    params["cwd"] = cwd
                if body.get("label") is not None:
                    params["label"] = _string(body.get("label"), "label", maximum=120)
                return service.invoke("workspace.create", params)
            if len(tail) >= 2 and tail[0] == "workspaces":
                workspace_id = _identifier(tail[1], "workspace ID")
                if method == "PATCH" and len(tail) == 2:
                    return service.invoke(
                        "workspace.rename",
                        {"workspace_id": workspace_id, "label": _string(body.get("label"), "label", maximum=120)},
                    )
                if method == "DELETE" and len(tail) == 2:
                    return service.invoke("workspace.close", {"workspace_id": workspace_id})
                if method == "POST" and len(tail) == 3 and tail[2] == "focus":
                    return service.invoke("workspace.focus", {"workspace_id": workspace_id})
                if method == "POST" and len(tail) == 3 and tail[2] == "tabs":
                    params = {
                        "workspace_id": workspace_id,
                        "focus": _boolean(body.get("focus"), "focus", default=True),
                        "env": _optional_env(body),
                    }
                    cwd = _optional_cwd(body)
                    if cwd is not None:
                        params["cwd"] = cwd
                    if body.get("label") is not None:
                        params["label"] = _string(body.get("label"), "label", maximum=120)
                    return service.invoke("tab.create", params)
            if len(tail) >= 2 and tail[0] == "tabs":
                tab_id = _identifier(tail[1], "tab ID")
                if method == "PATCH" and len(tail) == 2:
                    return service.invoke(
                        "tab.rename",
                        {"tab_id": tab_id, "label": _string(body.get("label"), "label", maximum=120)},
                    )
                if method == "DELETE" and len(tail) == 2:
                    return service.invoke("tab.close", {"tab_id": tab_id})
                if method == "POST" and len(tail) == 3 and tail[2] == "focus":
                    return service.invoke("tab.focus", {"tab_id": tab_id})
            if len(tail) >= 2 and tail[0] == "panes":
                pane_id = _identifier(tail[1], "pane ID")
                if method == "PATCH" and len(tail) == 2:
                    if "label" not in body:
                        raise HTTPValidationError("label is required")
                    label = body.get("label")
                    if label is not None:
                        label = _string(label, "label", maximum=120, allow_empty=True) or None
                    result = service.invoke("pane.rename", {"pane_id": pane_id, "label": label})
                    result["tabRenamed"] = self._fan_out_pane_rename(pane_id, label, result)
                    return result
                if method == "DELETE" and len(tail) == 2:
                    return service.invoke("pane.close", {"pane_id": pane_id})
                if method == "POST" and len(tail) == 3:
                    action = tail[2]
                    if action == "focus":
                        return service.invoke("pane.focus", {"pane_id": pane_id})
                    if action == "zoom":
                        mode = body.get("mode", "toggle")
                        if mode not in {"toggle", "on", "off"}:
                            raise HTTPValidationError("mode must be toggle, on, or off")
                        return service.invoke("pane.zoom", {"pane_id": pane_id, "mode": mode})
                    if action == "split":
                        direction = body.get("direction", "right")
                        if direction not in {"right", "down"}:
                            raise HTTPValidationError("direction must be right or down")
                        params = {
                            "target_pane_id": pane_id,
                            "direction": direction,
                            "focus": _boolean(body.get("focus"), "focus", default=True),
                            "env": _optional_env(body),
                        }
                        cwd = _optional_cwd(body)
                        if cwd is not None:
                            params["cwd"] = cwd
                        if body.get("ratio") is not None:
                            ratio = body.get("ratio")
                            if not isinstance(ratio, (int, float)) or isinstance(ratio, bool) or not 0.05 <= float(ratio) <= 0.95:
                                raise HTTPValidationError("ratio must be between 0.05 and 0.95")
                            params["ratio"] = float(ratio)
                        response = service.invoke("pane.split", params)
                        response["paneId"] = _find_pane_id(response.get("result"))
                        return response
                    if action == "send-text":
                        text = _string(body.get("text"), "text", maximum=131072, allow_empty=True)
                        return service.invoke("pane.send_text", {"pane_id": pane_id, "text": text})
                    if action == "send-keys":
                        keys = body.get("keys")
                        if not isinstance(keys, list) or not 1 <= len(keys) <= 64:
                            raise HTTPValidationError("keys must be a non-empty array with at most 64 entries")
                        if any(not isinstance(item, str) or not _KEY_RE.fullmatch(item) for item in keys):
                            raise HTTPValidationError("keys contains an invalid key name")
                        return service.invoke("pane.send_keys", {"pane_id": pane_id, "keys": keys})
                    if action == "run":
                        command = _string(body.get("command"), "command", maximum=32768)
                        return service.invoke(
                            "pane.send_input",
                            {"pane_id": pane_id, "text": command, "keys": ["enter"]},
                        )
                    if action == "prompt":
                        return self._prompt(pane_id, body)
                    if action == "star":
                        if "starred" not in body:
                            raise HTTPValidationError("starred is required")
                        starred = _boolean(body.get("starred"), "starred")
                        result = service.set_pane_star(pane_id, starred)
                        if result is None:
                            raise HTTPValidationError("Pane not found", code="pane_not_found", status=404)
                        return result
                    if action in {"start-agent", "agents"}:
                        return self._start_agent(pane_id, body)
                if len(tail) >= 4 and tail[2] == "pi":
                    pi_action = tail[3]
                    if method == "POST" and len(tail) == 4 and pi_action in {
                        "prompt",
                        "steer",
                        "follow-up",
                        "abort",
                    }:
                        payload: dict[str, Any] = {}
                        if pi_action != "abort":
                            payload["text"] = _string(body.get("text"), "text", maximum=131072)
                        return service.pi_command(pane_id, pi_action.replace("-", "_"), payload)
                    if method == "POST" and len(tail) == 4 and pi_action == "model":
                        allowed_keys = {"provider", "id"}
                        if set(body) != allowed_keys:
                            raise HTTPValidationError("Request body must contain exactly provider and id")
                        provider = _string(body.get("provider"), "provider", maximum=256)
                        model_id = _string(body.get("id"), "id", maximum=256)
                        return service.pi_command(
                            pane_id,
                            "set_model",
                            {"provider": provider, "id": model_id},
                        )
                    if method == "POST" and len(tail) == 4 and pi_action == "thinking-level":
                        allowed_keys = {"level"}
                        if set(body) != allowed_keys:
                            raise HTTPValidationError("Request body must contain exactly level")
                        level = _string(body.get("level"), "level", maximum=64)
                        return service.pi_command(pane_id, "set_thinking_level", {"level": level})
                    if (
                        method == "POST"
                        and len(tail) == 6
                        and pi_action == "interactions"
                        and tail[5] == "respond"
                    ):
                        interaction_id = _identifier(tail[4], "interaction ID")
                        allowed = {"value", "confirmed", "cancelled"}
                        if any(key not in allowed for key in body):
                            raise HTTPValidationError("interaction response contains an unsupported field")
                        if "value" in body:
                            value = body["value"]
                            if not isinstance(value, str) or len(value) > 131072 or "\x00" in value:
                                raise HTTPValidationError("interaction value is invalid")
                        for key in ("confirmed", "cancelled"):
                            if key in body and not isinstance(body[key], bool):
                                raise HTTPValidationError(f"{key} must be a boolean")
                        return service.pi_command(
                            pane_id,
                            "interaction_response",
                            {"interactionId": interaction_id, **body},
                        )
            if method == "POST" and len(tail) == 3 and tail[0] == "agents" and tail[2] == "prompt":
                return self._prompt(_identifier(tail[1], "agent target"), body)
            if method == "POST" and tail == ["quick-sessions", "pi"]:
                label = _string(body.get("label"), "label", maximum=120)
                return service.quick_pi_session(label)
            if method == "POST" and tail == ["alerts", "read-all"]:
                return service.mark_all_alerts_read()
            if method == "POST" and len(tail) == 3 and tail[0] == "alerts" and tail[2] == "read":
                alert_id = _identifier(tail[1], "alert ID")
                result = service.mark_alert_read(alert_id)
                if result is None:
                    raise HTTPValidationError("Alert not found", code="not_found", status=404)
                return result
            if method == "POST" and tail in (["push", "devices"], ["push", "register"]):
                token = _string(body.get("deviceToken") or body.get("token"), "deviceToken", maximum=512)
                bundle_id = body.get("bundleId", "")
                if not isinstance(bundle_id, str) or len(bundle_id) > 255:
                    raise HTTPValidationError("bundleId is invalid")
                environment = str(body.get("environment") or "sandbox").strip().lower()
                if environment not in {"sandbox", "production"}:
                    raise HTTPValidationError("environment must be sandbox or production")
                try:
                    return service.register_push_device(
                        token,
                        bundle_id=bundle_id,
                        environment=environment,
                    )
                except ValueError as exc:
                    raise HTTPValidationError(str(exc)) from exc
            if method == "POST" and tail == ["push", "unregister"]:
                token = _string(body.get("deviceToken") or body.get("token"), "deviceToken", maximum=512)
                try:
                    return service.unregister_push_device(token)
                except ValueError as exc:
                    raise HTTPValidationError(str(exc)) from exc
            if method == "POST" and tail == ["live-activities"]:
                activity_id = _identifier(body.get("activityId"), "activity ID")
                token = _string(body.get("pushToken"), "pushToken", maximum=512)
                bundle_id = _string(body.get("bundleId"), "bundleId", maximum=255)
                environment = str(body.get("environment") or "sandbox").strip().lower()
                if environment not in {"sandbox", "production"}:
                    raise HTTPValidationError("environment must be sandbox or production")
                try:
                    return service.register_live_activity(
                        token,
                        activity_id=activity_id,
                        bundle_id=bundle_id,
                        environment=environment,
                    )
                except ValueError as exc:
                    raise HTTPValidationError(str(exc)) from exc
            if method == "POST" and tail == ["live-activities", "unregister"]:
                activity_id = _identifier(body.get("activityId"), "activity ID")
                token = body.get("pushToken")
                if token is not None and not isinstance(token, str):
                    raise HTTPValidationError("pushToken must be a string")
                try:
                    return service.unregister_live_activity(
                        activity_id,
                        push_token=token,
                    )
                except ValueError as exc:
                    raise HTTPValidationError(str(exc)) from exc
            raise HTTPValidationError("Endpoint not found", code="not_found", status=404)

        def _prompt(self, target: str, body: dict) -> dict:
            text = _string(body.get("text"), "text", maximum=131072)
            params: dict[str, Any] = {"target": target, "text": text}
            wait_requested = _boolean(body.get("wait"), "wait", default=False)
            if wait_requested:
                until = body.get("until")
                if until is None:
                    statuses: list[str] = []
                elif isinstance(until, str):
                    statuses = [until]
                elif isinstance(until, list) and all(isinstance(item, str) for item in until):
                    statuses = list(until)
                else:
                    raise HTTPValidationError("until must be a status or status array")
                if any(item not in _AGENT_STATUSES for item in statuses):
                    raise HTTPValidationError("until contains an invalid agent status")
                timeout = body.get("timeoutMs", 120000)
                if not isinstance(timeout, int) or isinstance(timeout, bool) or not 100 <= timeout <= 300000:
                    raise HTTPValidationError("timeoutMs must be between 100 and 300000")
                params["wait"] = {"until": statuses, "timeout_ms": timeout}
            elif "until" in body or "timeoutMs" in body:
                raise HTTPValidationError("until and timeoutMs require wait=true")
            return service.invoke("agent.prompt", params)

        def _fan_out_pane_rename(self, pane_id: str, label: Optional[str], result: dict) -> bool:
            try:
                tab_id = None
                native_result = result.get("result") if isinstance(result, dict) else None
                pane = native_result.get("pane") if isinstance(native_result, dict) else None
                if isinstance(pane, dict):
                    tab_id = pane.get("tab_id")
                snapshot_response = service.snapshot_response()
                snapshot = snapshot_response.get("snapshot", {}) if isinstance(snapshot_response, dict) else {}
                panes = snapshot.get("panes", []) if isinstance(snapshot, dict) else []
                if not isinstance(panes, list):
                    panes = []
                if not tab_id:
                    for pane in panes:
                        if isinstance(pane, dict) and str(pane.get("pane_id")) == str(pane_id):
                            tab_id = pane.get("tab_id")
                            break
                if not tab_id:
                    return False
                if sum(
                    1
                    for pane in panes
                    if isinstance(pane, dict) and str(pane.get("tab_id")) == str(tab_id)
                ) != 1:
                    return False
                try:
                    service.invoke("tab.rename", {"tab_id": tab_id, "label": label})
                except HerdrClientError:
                    return False
                return True
            except Exception:
                return False

        def _start_agent(self, pane_id: str, body: dict) -> dict:
            name = _string(body.get("name"), "name", maximum=32)
            if not _AGENT_NAME_RE.fullmatch(name):
                raise HTTPValidationError("name must match [a-z][a-z0-9_-]{0,31}")
            kind = _string(body.get("kind"), "kind", maximum=32)
            if kind not in _AGENT_KINDS:
                raise HTTPValidationError("kind is not supported by this Herdr Harness version")
            args = body.get("args", [])
            if not isinstance(args, list) or len(args) > 64:
                raise HTTPValidationError("args must be an array with at most 64 entries")
            clean_args = []
            for item in args:
                clean_args.append(_string(item, "agent argument", maximum=4096, allow_empty=True))
            if kind == "pi" and not clean_args:
                clean_args = service.pi_extension_args()
            timeout = body.get("timeoutMs", 30000)
            if not isinstance(timeout, int) or isinstance(timeout, bool) or not 3001 <= timeout <= 300000:
                raise HTTPValidationError("timeoutMs must be greater than 3000 and at most 300000")
            return service.invoke(
                "agent.start",
                {"pane_id": pane_id, "name": name, "kind": kind, "args": clean_args, "timeout_ms": timeout},
            )

        def _serve_events(self, query: dict[str, list[str]]) -> None:
            header_id = self.headers.get("Last-Event-ID")
            has_cursor = header_id is not None or "after" in query
            raw_id = header_id if header_id is not None else (query.get("after") or ["0"])[0]
            try:
                last_id = max(0, int(raw_id))
            except (TypeError, ValueError) as exc:
                raise HTTPValidationError("Last-Event-ID must be an integer") from exc
            once = _query_bool(query, "once", False)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self._common_headers()
            self.end_headers()
            latest_id = service.broker.latest_id
            oldest_id = service.broker.oldest_id
            reset_reason = None
            if not has_cursor:
                # A fresh client needs one compact refresh trigger, not every
                # historical event which can each cause a full workspace fetch.
                last_id = latest_id
            elif last_id > latest_id:
                reset_reason = "backend_restarted"
                last_id = 0
            elif last_id and last_id < oldest_id - 1:
                reset_reason = "replay_gap"
                last_id = oldest_id - 1
            ready = {
                "event": "ready",
                "generatedAt": utc_now(),
                "lastEventId": latest_id,
                "oldestEventId": oldest_id,
                "resumeFrom": last_id,
            }
            self.wfile.write(b"retry: 1000\n")
            self.wfile.write(f"event: ready\ndata: {json.dumps(ready, separators=(',', ':'))}\n\n".encode("utf-8"))
            if reset_reason:
                reset = {
                    "event": "stream.reset",
                    "reason": reset_reason,
                    "resumeAfter": last_id,
                    "generatedAt": utc_now(),
                }
                self.wfile.write(
                    f"event: stream.reset\ndata: {json.dumps(reset, separators=(',', ':'))}\n\n".encode("utf-8")
                )
            if not has_cursor:
                synthetic = {
                    "generatedAt": utc_now(),
                    "initial": True,
                    "synthetic": True,
                    "paneRevisions": {},
                }
                self.wfile.write(
                    f"event: snapshot.updated\ndata: {json.dumps(synthetic, separators=(',', ':'))}\n\n".encode("utf-8")
                )
            self.wfile.flush()

            def write_events(events: list[dict]) -> int:
                cursor = last_id
                for item in events:
                    event_name = _EVENT_NAME_RE.sub("_", str(item.get("event") or "message"))
                    payload = json.dumps(item, separators=(",", ":"), ensure_ascii=False)
                    self.wfile.write(
                        f"id: {item['id']}\nevent: {event_name}\ndata: {payload}\n\n".encode("utf-8")
                    )
                    self.wfile.flush()
                    cursor = max(cursor, int(item["id"]))
                return cursor

            if once:
                last_id = write_events(service.broker.after(last_id))
                self.close_connection = True
                return
            while True:
                events = service.broker.wait_after(last_id, timeout=15.0)
                if not events:
                    self.wfile.write(f": heartbeat {utc_now()}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    continue
                last_id = write_events(events)

        def _serve_terminal_stream(self, pane_id: str, *, cols: int, rows: int) -> None:
            observer = service.terminal_observer(pane_id, cols=cols, rows=rows)
            try:
                observer.start()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Connection", "keep-alive")
                self.send_header("X-Accel-Buffering", "no")
                self._common_headers()
                self.end_headers()
                self.wfile.write(
                    f"event: ready\ndata: {json.dumps({'paneId': pane_id, 'cols': cols, 'rows': rows})}\n\n".encode("utf-8")
                )
                self.wfile.flush()
                started_at = time.monotonic()
                with observer:
                    for frame in observer.frames():
                        if time.monotonic() - started_at >= service.terminal_max_seconds:
                            payload = json.dumps({"reason": "lifetime_limit"}, separators=(",", ":"))
                            self.wfile.write(f"event: terminal.closed\ndata: {payload}\n\n".encode("utf-8"))
                            self.wfile.flush()
                            break
                        if frame.get("event") == "heartbeat":
                            self.wfile.write(f": terminal heartbeat {utc_now()}\n\n".encode("utf-8"))
                        else:
                            event_name = _EVENT_NAME_RE.sub("_", str(frame.get("event") or "terminal.frame"))
                            payload = json.dumps(frame.get("data") or {}, separators=(",", ":"), ensure_ascii=False)
                            self.wfile.write(f"event: {event_name}\ndata: {payload}\n\n".encode("utf-8"))
                        self.wfile.flush()
            finally:
                observer.close()
                service.release_terminal_observer()

        def _serve_pi_events(self, pane_id: str, query: dict[str, list[str]]) -> None:
            # Validate availability and pane identity before committing an SSE
            # response. A disconnected bridge may still have a useful durable
            # snapshot, so snapshot_response intentionally permits that state.
            service.pi_snapshot_response(pane_id)
            raw_id = self.headers.get("Last-Event-ID") or (query.get("after") or ["0"])[0]
            try:
                last_id = max(0, int(raw_id))
            except (TypeError, ValueError) as exc:
                raise HTTPValidationError("Last-Event-ID must be an integer") from exc
            once = _query_bool(query, "once", False)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self._common_headers()
            self.end_headers()

            oldest_id, latest_id = service.pi_semantic.bounds(pane_id)
            pi_snapshot = service.pi_snapshot_response(pane_id)
            reset_reason = None
            if last_id > latest_id:
                reset_reason = "backend_restarted"
                last_id = latest_id
            elif last_id and last_id < oldest_id - 1:
                reset_reason = "replay_gap"
                last_id = oldest_id - 1
            ready = {
                "protocol": PI_SEMANTIC_PROTOCOL,
                "pane_id": pane_id,
                # This is the cursor already represented by the client. Using
                # latest_id here could make a disconnect after `ready` skip
                # journal events that have not been sent yet.
                "cursor": last_id,
                "latest_cursor": latest_id,
                "oldest_cursor": oldest_id,
                "connected": bool(pi_snapshot.get("connected")),
                "event": {
                    "type": "ready",
                    "connected": bool(pi_snapshot.get("connected")),
                },
                "generated_at": utc_now(),
            }
            self.wfile.write(b"retry: 1000\n")
            self.wfile.write(
                f"event: pi.ready\ndata: {json.dumps(ready, separators=(',', ':'))}\n\n".encode("utf-8")
            )
            if reset_reason:
                reset = {
                    "protocol": PI_SEMANTIC_PROTOCOL,
                    "pane_id": pane_id,
                    "cursor": latest_id,
                    "event": {
                        "type": "stream.reset",
                        "reason": reset_reason,
                        "resumeAfter": last_id,
                    },
                    "generated_at": utc_now(),
                }
                self.wfile.write(
                    f"event: pi.stream.reset\ndata: {json.dumps(reset, separators=(',', ':'))}\n\n".encode("utf-8")
                )
            self.wfile.flush()
            if once:
                self.close_connection = True
                return
            while True:
                events = service.pi_semantic.wait_after(pane_id, last_id, timeout=15.0)
                if not events:
                    self.wfile.write(f": heartbeat {utc_now()}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    continue
                for item in events:
                    event = item.get("event") if isinstance(item.get("event"), dict) else {}
                    event_type = _EVENT_NAME_RE.sub("_", str(event.get("type") or "event"))
                    cursor = int(item.get("cursor") or last_id)
                    payload = json.dumps(item, separators=(",", ":"), ensure_ascii=False)
                    self.wfile.write(
                        f"id: {cursor}\nevent: pi.{event_type}\ndata: {payload}\n\n".encode("utf-8")
                    )
                    self.wfile.flush()
                    last_id = max(last_id, cursor)

        def do_OPTIONS(self) -> None:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, Last-Event-ID")
            self._common_headers()
            self.end_headers()

        def do_GET(self) -> None:
            self._dispatch("GET")

        def do_POST(self) -> None:
            self._dispatch("POST")

        def do_PATCH(self) -> None:
            self._dispatch("PATCH")

        def do_DELETE(self) -> None:
            self._dispatch("DELETE")

    return HerdrHandler


class HerdrHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request: Any, client_address: Any) -> None:
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionAbortedError, ConnectionResetError)):
            return
        if isinstance(exc, OSError) and exc.errno in _DISCONNECT_ERRNOS:
            return
        socketserver.BaseServer.handle_error(self, request, client_address)


def make_server(
    service: HerdrService,
    *,
    host: str = "127.0.0.1",
    port: int = 9092,
    api_token: Optional[str] = None,
) -> HerdrHTTPServer:
    server = HerdrHTTPServer((host, int(port)), make_handler(service, api_token=api_token))
    server.service = service
    return server
