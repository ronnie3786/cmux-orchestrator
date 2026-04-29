import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import uuid

from . import attachments
from . import cmux_api
from . import objectives
from . import push_notifications
from . import workspaces
from . import review as review_mod
from . import storage
from .engine import OLLAMA_URL
from .routes import action_buttons as action_buttons_routes
from .routes import build_log as build_log_routes
from .routes import console_logs as console_logs_routes
from .routes import file_browser as file_browser_routes
from .routes import objectives as objective_routes
from .routes import projects as project_routes
from .routes import status_summary as status_summary_routes
from .routes import hooks as hooks_routes
from .routes import workspaces as workspace_routes

_STATIC_DIR = Path(__file__).parent / "static"
_STATIC_FILES = {
    "/": ("orchestrator.html", "text/html; charset=utf-8"),
    "/harness": ("dashboard.html", "text/html; charset=utf-8"),
    "/orchestrator.css": ("orchestrator.css", "text/css; charset=utf-8"),
    "/orchestrator.js": ("orchestrator.js", "application/javascript; charset=utf-8"),
}


def _read_static_file(filename, fallback):
    try:
        return (_STATIC_DIR / filename).read_text(encoding="utf-8")
    except FileNotFoundError:
        return fallback


DASHBOARD_HTML = _read_static_file("dashboard.html", "<html><body><h1>dashboard.html not found</h1></body></html>")
ORCHESTRATOR_HTML = _read_static_file("orchestrator.html", "<html><body><h1>orchestrator.html not found</h1></body></html>")
ORCHESTRATOR_CSS = _read_static_file("orchestrator.css", "/* orchestrator.css not found */\n")
ORCHESTRATOR_JS = _read_static_file("orchestrator.js", "console.error('orchestrator.js not found');\n")
_STATIC_CONTENT = {
    "/": ORCHESTRATOR_HTML,
    "/harness": DASHBOARD_HTML,
    "/orchestrator.css": ORCHESTRATOR_CSS,
    "/orchestrator.js": ORCHESTRATOR_JS,
}

_HARNESS_ALLOWED_KEYS = {"up", "down", "tab", "enter"}


def _human_file_size(size):
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(max(0, int(size or 0)))
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024.0


def make_handler(engine):
    """Create a DashboardHandler class bound to the given engine instance."""

    class DashboardHandler(BaseHTTPRequestHandler):
        parse_qs = staticmethod(urllib.parse.parse_qs)

        def log_message(self, fmt, *args):
            pass

        def _json_response(self, data, status=200):
            body = json.dumps(data).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                return False
            return True

        def _read_body(self):
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                return json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                return {}

        def _handle_post_attachment(self):
            try:
                content_length = int(self.headers.get("Content-Length", "0") or "0")
            except (TypeError, ValueError):
                self._json_response({"ok": False, "error": "content length required"}, 411)
                return
            if content_length <= 0:
                self._json_response({"ok": False, "error": "file is empty"}, 400)
                return
            if content_length > attachments.MAX_ATTACHMENT_BYTES:
                self._json_response({"ok": False, "error": "file exceeds 20 MB limit"}, 413)
                return

            filename = self.headers.get("X-Cmux-Filename", "") or ""
            if not filename.strip():
                self._json_response({"ok": False, "error": "filename required"}, 400)
                return

            try:
                attachment = attachments.save_attachment_stream(
                    self.rfile,
                    content_length=content_length,
                    filename=filename,
                    content_type=self.headers.get("Content-Type", "") or "application/octet-stream",
                    workspace_uuid=self.headers.get("X-Cmux-Workspace-UUID", "") or "",
                    workspace_index=self.headers.get("X-Cmux-Workspace-Index", "") or "",
                )
            except ValueError as exc:
                message = str(exc) or "invalid attachment"
                status = 413 if "20 MB" in message else 400
                self._json_response({"ok": False, "error": message}, status)
                return
            except OSError as exc:
                self._json_response({"ok": False, "error": str(exc)}, 500)
                return

            self._json_response({"ok": True, "attachment": attachment})

        def _resolve_git_path(self, path_value):
            cwd = os.path.expanduser(str(path_value or "").strip())
            if not cwd:
                return None
            if not os.path.isdir(cwd):
                return None
            return cwd

        def _resolve_workspace_file_path(self, root_path, file_value):
            root = os.path.realpath(str(root_path or "").strip())
            if not root or not os.path.isdir(root):
                return None, "workspace cwd not found"
            raw_file = str(file_value or "").strip().replace("\\", "/")
            if not raw_file:
                return None, "file required"

            candidates = [raw_file]
            if " -> " in raw_file:
                old_path, new_path = raw_file.split(" -> ", 1)
                candidates = [new_path.strip(), old_path.strip()]

            root_prefix = root + os.sep
            for candidate in candidates:
                full_path = os.path.realpath(os.path.join(root, candidate))
                if full_path != root and not full_path.startswith(root_prefix):
                    continue
                if os.path.exists(full_path):
                    return full_path, None

            return None, f"file not found: {raw_file}"

        def _serve_static(self, path):
            content = _STATIC_CONTENT.get(path)
            meta = _STATIC_FILES.get(path)
            if content is None or meta is None:
                return False
            body = content.encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", meta[1])
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                return False
            return True

        def _serve_events(self, parsed):
            params = urllib.parse.parse_qs(parsed.query)
            target_type = params.get("targetType", [""])[0]
            target_id = params.get("targetId", [""])[0]
            try:
                after = int(params.get("after", ["0"])[0] or 0)
            except (TypeError, ValueError):
                after = 0
            if after <= 0:
                try:
                    after = int(self.headers.get("Last-Event-ID", "0") or 0)
                except (TypeError, ValueError):
                    after = 0

            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()
                self.wfile.write(b": connected\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return False

            while True:
                try:
                    events = self.server.engine.orchestrator.wait_events_after(
                        after,
                        timeout=15.0,
                        target_type=target_type,
                        target_id=target_id,
                    )
                    if not events:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        continue
                    for event in events:
                        after = max(after, int(event.get("seq") or 0))
                        body = json.dumps(event).encode("utf-8")
                        self.wfile.write(f"id: {after}\n".encode("utf-8"))
                        self.wfile.write(f"event: {event.get('kind') or 'message'}\n".encode("utf-8"))
                        self.wfile.write(b"data: ")
                        self.wfile.write(body)
                        self.wfile.write(b"\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return False

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path
            if self._serve_static(path):
                return
            if path == "/api/events":
                self._serve_events(parsed)
            elif path == "/api/status":
                self._json_response(engine.get_status())
            elif path == "/api/log":
                self._json_response(engine.get_log())
            elif path.startswith("/api/git-status"):
                params = urllib.parse.parse_qs(parsed.query)
                if path == "/api/git-status-path":
                    target_path = self._resolve_git_path(params.get("path", [None])[0])
                    if target_path is None:
                        self._json_response({"ok": False, "error": "path required"}, 400)
                        return
                    result = engine.get_git_status_for_path(target_path)
                else:
                    idx_str = params.get("index", [None])[0]
                    if idx_str is None:
                        self._json_response({"ok": False, "error": "index required"}, 400)
                        return
                    result = engine.get_git_status(int(idx_str))
                if result is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                result["ok"] = True
                cwd = result.get("cwd")
                if cwd and os.path.isdir(cwd):
                    result["editorTargets"] = file_browser_routes.editor_targets_for_root(Path(cwd).expanduser().resolve())
                self._json_response(result)
            elif path.startswith("/api/screen"):
                params = urllib.parse.parse_qs(parsed.query)
                idx_str = params.get("index", [None])[0]
                lines_str = params.get("lines", ["200"])[0]
                if idx_str is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                idx = int(idx_str)
                lines = min(int(lines_str), 500)
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                ws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                if ws is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                ws_uuid = ws.get("uuid", "")
                sid = ws.get("_surface_id")
                real_idx = ws.get("_real_index", idx)
                screen = ""
                if ws_uuid:
                    screen = cmux_api.cmux_read_workspace(
                        real_idx, 0, lines=lines,
                        workspace_uuid=ws_uuid, surface_id=sid
                    ) or ""
                self._json_response({"ok": True, "screen": screen, "lines": lines})
            elif path == "/api/reviews":
                reviews = []
                for review in storage.list_reviews():
                    item = dict(review)
                    item["gitDiff"] = (item.get("gitDiff") or "")[:500]
                    reviews.append(item)
                self._json_response(reviews)
            elif path == "/api/projects":
                project_routes.handle_list_projects(self)
            elif path.startswith("/api/projects/"):
                project_id = urllib.parse.unquote(path[len("/api/projects/"):]).strip("/")
                project = objectives.read_project(project_id)
                if project is None:
                    self._json_response({"ok": False, "error": "project not found"}, 404)
                    return
                project_routes.handle_get_project(self, project)
            elif path == "/api/objectives":
                objective_routes.handle_list_objectives(self)
            elif path == "/api/workspaces":
                workspace_routes.handle_list_workspaces(self)
            elif path == "/api/skills":
                file_browser_routes.handle_get_skills(self, parsed, engine=self.server.engine)
            elif path == "/api/file-search":
                file_browser_routes.handle_search_files(self, parsed, engine=self.server.engine)
            elif path.startswith("/api/objectives/") and path.endswith("/action-buttons"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/action-buttons")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                action_buttons_routes.handle_get_action_buttons(self, objective)
            elif path.startswith("/api/objectives/") and path.endswith("/build-log"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/build-log")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                build_log_routes.handle_get_build_log(
                    self,
                    objective,
                    parsed,
                    human_file_size=_human_file_size,
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/build-log"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/build-log")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                build_log_routes.handle_get_workspace_build_log(
                    self,
                    workspace,
                    parsed,
                    human_file_size=_human_file_size,
                )
            elif path.startswith("/api/objectives/") and path.endswith("/console-logs"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/console-logs")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                console_logs_routes.handle_get_console_logs(
                    self,
                    objective,
                    parsed,
                    re_module=__import__("re"),
                    human_file_size=_human_file_size,
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/console-logs"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/console-logs")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                console_logs_routes.handle_get_workspace_console_logs(
                    self,
                    workspace,
                    parsed,
                    re_module=__import__("re"),
                    human_file_size=_human_file_size,
                )
            elif path.startswith("/api/objectives/") and path.endswith("/status-summary"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/status-summary")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                status_summary_routes.handle_get_status_summary(
                    self,
                    objective_id,
                    objective,
                    engine=self.server.engine,
                    parsed=parsed,
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/status-summary"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/status-summary")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                status_summary_routes.handle_get_workspace_status_summary(
                    self,
                    workspace_id,
                    workspace,
                    engine=self.server.engine,
                    parsed=parsed,
                )
            elif path.startswith("/api/objectives/") and "/tasks/" in path and path.endswith("/screen"):
                parts = path.split("/")
                objective_id = parts[3]
                task_id = parts[5]
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "Not found"}, 404)
                    return
                objective_routes.handle_get_task_screen(self, objective, task_id)
            elif path.startswith("/api/objectives/") and path.endswith("/screen"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/screen")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                objective_routes.handle_get_screen(self, objective, parsed)
            elif path.startswith("/api/objectives/") and "/messages" in path:
                objective_id = path.split("/")[3]
                objective_routes.handle_get_messages(self, objective_id, parsed, engine=self.server.engine)
            elif path.startswith("/api/workspaces/") and path.endswith("/messages"):
                workspace_id = path.split("/")[3]
                if workspaces.read_workspace_session(workspace_id) is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_get_messages(self, workspace_id, parsed, engine=self.server.engine)
            elif path.startswith("/api/workspaces/") and path.endswith("/active-turn"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/active-turn")]).strip("/")
                if workspaces.read_workspace_session(workspace_id) is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_get_active_turn(self, workspace_id)
            elif path.startswith("/api/workspaces/") and path.endswith("/screen"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/screen")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_get_screen(self, workspace, parsed)
            elif path.startswith("/api/objectives/") and path.endswith("/debug"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/debug")]).strip("/")
                if objectives.read_objective(objective_id) is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                objective_routes.handle_get_debug(self, objective_id, parsed, engine=self.server.engine)
            elif path.startswith("/api/workspaces/") and path.endswith("/debug"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/debug")]).strip("/")
                if workspaces.read_workspace_session(workspace_id) is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_get_debug(self, workspace_id, parsed)
            elif path.startswith("/api/workspaces/") and path.endswith("/action-buttons"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/action-buttons")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                action_buttons_routes.handle_get_workspace_action_buttons(self, workspace)
            elif path.startswith("/api/objectives/"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                objective_routes.handle_get_objective(self, objective)
            elif path.startswith("/api/workspaces/"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_get_workspace(self, workspace)
            elif path.startswith("/api/reviews/"):
                session_id = urllib.parse.unquote(path[len("/api/reviews/"):])
                review = storage.get_review(session_id)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                self._json_response(review)
            elif path == "/api/config":
                with engine._lock:
                    self._json_response({
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                        "contractReviewEnabled": engine.contract_review_enabled,
                        "approvalThreshold": getattr(engine, "approval_threshold", 3),
                        "defaultProjectDir": engine.default_project_dir,
                        "defaultBaseBranch": engine.default_base_branch,
                    })
            elif path == "/api/models":
                with engine._lock:
                    cached = engine.ollama_available
                lmstudio_available = False
                claude_available = shutil.which("claude") is not None
                try:
                    with urllib.request.urlopen("http://100.89.93.84:1234/v1/models", timeout=3) as r:
                        json.loads(r.read())
                    lmstudio_available = True
                except Exception:
                    lmstudio_available = False
                if cached is False:
                    self._json_response({
                        "models": [],
                        "available": False,
                        "lmstudioAvailable": lmstudio_available,
                        "claudeAvailable": claude_available,
                    })
                else:
                    try:
                        import urllib.request as _ur
                        with _ur.urlopen(f"{OLLAMA_URL}/api/tags", timeout=4) as r:
                            data = json.loads(r.read())
                        names = [m["name"] for m in data.get("models", [])]
                        with engine._lock:
                            engine.ollama_available = True
                            engine.ollama_last_check = time.time()
                        self._json_response({
                            "models": names,
                            "available": True,
                            "lmstudioAvailable": lmstudio_available,
                            "claudeAvailable": claude_available,
                        })
                    except Exception as e:
                        with engine._lock:
                            engine.ollama_available = False
                            engine.ollama_last_check = time.time()
                        self._json_response({
                            "models": [],
                            "available": False,
                            "lmstudioAvailable": lmstudio_available,
                            "claudeAvailable": claude_available,
                            "error": str(e),
                        })
            else:
                self.send_error(404)

        def do_POST(self):
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/attachments":
                self._handle_post_attachment()
                return
            data = self._read_body()
            if path == "/api/toggle":
                engine.set_enabled(data.get("enabled", False))
                self._json_response({"ok": True, "enabled": engine.enabled})
            elif path.startswith("/api/objectives/") and path.endswith("/start"):
                objective_id = path.split("/")[3]
                objective_routes.handle_post_start(self, objective_id, engine=self.server.engine)
            elif path.startswith("/api/objectives/") and "/tasks/" in path and path.endswith("/approve"):
                parts = path.split("/")
                objective_id = parts[3]
                task_id = parts[5]
                objective_routes.handle_post_task_approve(
                    self,
                    objective_id,
                    task_id,
                    data,
                    engine=self.server.engine,
                )
            elif path.startswith("/api/objectives/") and path.endswith("/approve-hook"):
                objective_id = path.split("/")[3]
                objective_routes.handle_post_approve_hook(self, objective_id, data, engine=self.server.engine)
            elif path.startswith("/api/objectives/") and path.endswith("/approve-plan"):
                objective_id = path.split("/")[3]
                objective_routes.handle_post_approve_plan(self, objective_id, engine=self.server.engine)
            elif path.startswith("/api/objectives/") and path.endswith("/approve-contracts"):
                objective_id = path.split("/")[3]
                objective_routes.handle_approve_contracts(self, objective_id, engine=self.server.engine)
            elif path.startswith("/api/objectives/") and path.endswith("/message"):
                objective_id = path.split("/")[3]
                objective_routes.handle_post_message(
                    self,
                    objective_id,
                    data,
                    engine=self.server.engine,
                    threading_module=threading,
                )
            elif path.startswith("/api/objectives/") and path.endswith("/action-buttons"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/action-buttons")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                action_buttons_routes.handle_post_action_buttons(
                    self,
                    objective_id,
                    objective,
                    data,
                    uuid_module=uuid,
                )
            elif path.startswith("/api/objectives/") and path.endswith("/action-inject"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/action-inject")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                action_buttons_routes.handle_post_action_inject(
                    self,
                    objective_id,
                    objective,
                    data,
                    engine=self.server.engine,
                    cmux_api=cmux_api,
                    datetime_cls=datetime,
                    time_module=time,
                    re_module=__import__("re"),
                )
            elif path.startswith("/api/objectives/") and path.endswith("/open-worktree"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):-len("/open-worktree")]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                file_browser_routes.handle_open_worktree(self, objective, data.get("editor", "vscode"))
            elif path.startswith("/api/workspaces/") and path.endswith("/action-buttons"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/action-buttons")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                action_buttons_routes.handle_post_workspace_action_buttons(
                    self,
                    workspace_id,
                    workspace,
                    data,
                    uuid_module=uuid,
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/action-inject"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/action-inject")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                action_buttons_routes.handle_post_workspace_action_inject(
                    self,
                    workspace_id,
                    workspace,
                    data,
                    engine=self.server.engine,
                    cmux_api=cmux_api,
                    datetime_cls=datetime,
                    time_module=time,
                    re_module=__import__("re"),
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/start"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/start")]).strip("/")
                if workspaces.read_workspace_session(workspace_id) is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_post_start(self, workspace_id, engine=self.server.engine)
            elif path.startswith("/api/workspaces/") and "/turns/" in path and path.endswith("/finalize"):
                prefix = path[len("/api/workspaces/"):]
                workspace_part, turn_part = prefix.split("/turns/", 1)
                workspace_id = urllib.parse.unquote(workspace_part).strip("/")
                turn_id = urllib.parse.unquote(turn_part[:-len("/finalize")]).strip("/")
                workspace_routes.handle_post_finalize_turn(
                    self,
                    workspace_id,
                    turn_id,
                    data,
                    engine=self.server.engine,
                )
            elif path.startswith("/api/workspaces/") and path.endswith("/message"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/message")]).strip("/")
                if workspaces.read_workspace_session(workspace_id) is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_post_message(self, workspace_id, data, engine=self.server.engine, threading_module=threading)
            elif path.startswith("/api/workspaces/") and path.endswith("/open-root"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):-len("/open-root")]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                file_browser_routes.handle_open_workspace_root(self, workspace, data.get("editor", "vscode"))
            elif path == "/api/workspace-open-root":
                idx = data.get("index")
                if idx is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                try:
                    idx = int(idx)
                except (TypeError, ValueError):
                    self._json_response({"ok": False, "error": "invalid index"}, 400)
                    return
                cwd = engine._get_workspace_cwd(idx)
                if not cwd:
                    self._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
                    return
                file_browser_routes.handle_open_root_path(
                    self,
                    cwd,
                    "workspace cwd required",
                    "workspace cwd not found",
                    data.get("editor", "vscode"),
                )
            elif path == "/api/projects/pick-root":
                project_routes.handle_post_pick_project_root(self)
            elif path == "/api/projects":
                project_routes.handle_post_create_project(self, data)
            elif path == "/api/objectives":
                objective_routes.handle_post_create_objective(self, data, engine=self.server.engine)
            elif path == "/api/workspaces":
                workspace_routes.handle_post_create_workspace(self, data)
            elif path == "/api/resolve-dropped-files":
                file_browser_routes.handle_resolve_dropped_files(self, data)
            elif path == "/api/push/register":
                self._json_response(push_notifications.register_device(
                    data.get("token", ""),
                    data.get("bundleId", ""),
                    data.get("environment", ""),
                ))
            elif path == "/api/push/clear":
                self._json_response(push_notifications.clear_workspace_pending(
                    data.get("workspaceID", ""),
                    data.get("workspaceUUID", ""),
                    data.get("surfaceID", ""),
                ))
            elif path == "/api/workspace":
                idx = data.get("index")
                enabled = data.get("enabled", True)
                if idx is not None:
                    idx = int(idx)
                    with engine._lock:
                        virtual_ws = engine._build_virtual_workspaces()
                    vws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                    real_idx = vws.get("_real_index", idx) if vws else idx
                    engine.set_workspace_enabled(real_idx, enabled)
                self._json_response({"ok": True})
            elif path == "/api/workspace-star":
                idx = data.get("index")
                starred = data.get("starred", True)
                if idx is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                idx = int(idx)
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                vws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                real_idx = vws.get("_real_index", idx) if vws else idx
                ok = engine.set_workspace_starred(real_idx, starred)
                if not ok:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                self._json_response({"ok": True, "starred": bool(starred)})
            elif path == "/api/config":
                pi = data.get("pollInterval")
                if pi is not None:
                    engine.set_poll_interval(pi)
                model = data.get("model")
                if model is not None:
                    engine.set_model(model)
                review_enabled = data.get("reviewEnabled")
                review_model = data.get("reviewModel")
                review_backend = data.get("reviewBackend")
                if review_enabled is not None or review_model is not None or review_backend is not None:
                    engine.set_review_config(
                        enabled=review_enabled,
                        model=review_model,
                        backend=review_backend,
                    )
                contract_review_enabled = data.get("contractReviewEnabled")
                if contract_review_enabled is not None:
                    engine.set_contract_review_config(enabled=contract_review_enabled)
                approval_threshold = data.get("approvalThreshold")
                if approval_threshold is not None:
                    engine.set_approval_threshold(approval_threshold)
                default_project_dir = data.get("defaultProjectDir")
                default_base_branch = data.get("defaultBaseBranch")
                if default_project_dir is not None or default_base_branch is not None:
                    engine.set_default_objective_config(
                        project_dir=default_project_dir,
                        base_branch=default_base_branch,
                    )
                with engine._lock:
                    self._json_response({
                        "ok": True,
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                        "contractReviewEnabled": engine.contract_review_enabled,
                        "approvalThreshold": getattr(engine, "approval_threshold", 3),
                        "defaultProjectDir": engine.default_project_dir,
                        "defaultBaseBranch": engine.default_base_branch,
                    })
            elif path == "/api/rename":
                idx = data.get("index")
                name = data.get("name", "")
                if idx is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                idx = int(idx)
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                vws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                real_idx = vws.get("_real_index", idx) if vws else idx
                ok = engine.set_custom_name(real_idx, name)
                if not ok:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                self._json_response({"ok": True})
            elif path == "/api/send":
                idx = data.get("index")
                text = data.get("text", "")
                key = str(data.get("key") or "").strip().lower()
                surface_id = data.get("surfaceId")
                if idx is None or (not text and not key):
                    self._json_response({"ok": False, "error": "index and text or key required"}, 400)
                    return
                if key and key not in _HARNESS_ALLOWED_KEYS:
                    self._json_response({"ok": False, "error": f"unsupported key: {key}"}, 400)
                    return
                idx = int(idx)
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                ws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                if ws is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                sid = surface_id or ws.get("_surface_id")
                real_idx = ws.get("_real_index", idx)
                cmux_api.ensure_workspace_terminal_ready(
                    workspace_uuid=ws.get("uuid"),
                    surface_id=sid,
                )
                ok = cmux_api.cmux_send_to_workspace(
                    real_idx,
                    0,
                    text=text or None,
                    key=key or None,
                    workspace_uuid=ws.get("uuid"),
                    surface_id=sid,
                )
                if ok:
                    action = "user key" if key else "user input"
                    engine._append_log({
                        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "workspace": idx,
                        "workspaceName": ws.get("name", ws.get("surfaceLabel", "")),
                        "promptType": "manual-key" if key else "manual",
                        "action": action,
                        "key": key or None,
                        "surfaceId": sid,
                    })
                    with engine._lock:
                        engine.fingerprints.pop(idx, None)
                self._json_response({"ok": ok})
            elif path.startswith("/api/reviews/") and path.endswith("/rerun"):
                session_id = urllib.parse.unquote(path[len("/api/reviews/"):-len("/rerun")]).rstrip("/")
                review_path = storage.get_review_path(session_id)
                if review_path is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review = storage.read_review_file(review_path)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                model_override = data.get("model")
                backend_override = data.get("backend")
                review["reviewStatus"] = "pending"
                review.pop("reviewedAt", None)
                review.pop("reviewDuration", None)
                review.pop("reviewError", None)
                review.pop("reviewModel", None)
                review.pop("review", None)
                try:
                    storage.write_review_file(review_path, review)
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                threading.Thread(
                    target=review_mod.run_review,
                    args=(review_path, engine.review_model, engine.review_backend, model_override, backend_override),
                    daemon=True,
                ).start()
                self._json_response({"ok": True})
            elif path.startswith("/api/reviews/") and path.endswith("/dismiss"):
                session_id = urllib.parse.unquote(path[len("/api/reviews/"):-len("/dismiss")]).rstrip("/")
                review_path = storage.get_review_path(session_id)
                if review_path is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review = storage.read_review_file(review_path)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review["reviewStatus"] = "dismissed"
                try:
                    storage.write_review_file(review_path, review)
                except (OSError, UnicodeDecodeError) as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                self._json_response({"ok": True})
            elif path == "/api/new-session":
                project_path = data.get("projectPath", "~/Documents/Development/Doximity-Claude")
                branch_name = data.get("branchName", "")
                jira_url = data.get("jiraUrl", "")
                prompt = data.get("prompt", "")
                command = data.get("command", "claude")
                requested_session_name = str(data.get("sessionName", "")).strip()

                project_path = os.path.expanduser(project_path)

                if not os.path.isdir(project_path):
                    self._json_response({"ok": False, "error": f"Project directory not found: {project_path}"}, 400)
                    return

                cwd = project_path
                session_name = requested_session_name or branch_name or "New Session"

                if branch_name:
                    worktrees_dir = os.path.join(project_path, ".claude", "worktrees")
                    os.makedirs(worktrees_dir, exist_ok=True)
                    worktree_path = os.path.join(worktrees_dir, branch_name)

                    if os.path.exists(worktree_path):
                        self._json_response({"ok": False, "error": f"Worktree already exists: {branch_name}"}, 409)
                        return

                    try:
                        result = subprocess.run(
                            ["git", "worktree", "add", worktree_path, "-b", branch_name],
                            cwd=project_path, capture_output=True, text=True, timeout=30,
                        )
                        if result.returncode != 0:
                            err = (result.stderr or "").strip()
                            if "already exists" in err.lower():
                                result = subprocess.run(
                                    ["git", "worktree", "add", worktree_path, branch_name],
                                    cwd=project_path, capture_output=True, text=True, timeout=30,
                                )
                                if result.returncode != 0:
                                    self._json_response({"ok": False, "error": f"Worktree failed: {(result.stderr or '').strip()}"}, 500)
                                    return
                            else:
                                self._json_response({"ok": False, "error": f"Worktree failed: {err}"}, 500)
                                return
                    except subprocess.TimeoutExpired:
                        self._json_response({"ok": False, "error": "Worktree creation timed out"}, 500)
                        return
                    except OSError as e:
                        self._json_response({"ok": False, "error": f"Worktree error: {e}"}, 500)
                        return

                    cwd = worktree_path

                command_text = str(command or "").strip()
                command_name = command_text.split(None, 1)[0].lower() if command_text else ""
                if command_name == "claude":
                    orchestrator = getattr(engine, "orchestrator", None)
                    inject_hook_config = getattr(orchestrator, "_inject_hook_config", None)
                    if callable(inject_hook_config):
                        inject_hook_config(cwd)

                ws_uuid = None
                ws_idx = None
                cli_result = None

                def _ws_ids(list_result):
                    if not list_result:
                        return set()
                    ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                    return {w.get("id") or w.get("uuid") for w in ws_list if w.get("id") or w.get("uuid")}

                pre_list = cmux_api._v2_request("workspace.list", {})
                existing_ids = _ws_ids(pre_list)

                try:
                    cli_args = ["cmux", "new-workspace", "--name", session_name]
                    if cwd:
                        cli_args += ["--cwd", cwd]
                    if command_text:
                        cli_args += ["--command", command]
                    cli_result = subprocess.run(
                        cli_args, capture_output=True, text=True, timeout=10,
                    )
                    if cli_result.returncode != 0:
                        cli_result = None
                except (subprocess.TimeoutExpired, FileNotFoundError):
                    cli_result = None

                if cli_result is None:
                    create_result = cmux_api._v2_request("workspace.create", {})
                    if create_result is None:
                        self._json_response({"ok": False, "error": "Failed to create workspace"})
                        return

                list_result = cmux_api._v2_request("workspace.list", {})
                if list_result:
                    ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                    new_ws = next(
                        (w for w in ws_list if (w.get("id") or w.get("uuid")) not in existing_ids),
                        None,
                    )
                    if new_ws is None:
                        new_ws = next(
                            (w for w in reversed(ws_list) if w.get("title") == session_name or w.get("name") == session_name),
                            None,
                        )
                    if new_ws:
                        ws_uuid = new_ws.get("id") or new_ws.get("uuid")
                        ws_idx = new_ws.get("index")

                if not ws_uuid:
                    self._json_response({"ok": False, "error": "Failed to resolve new workspace"})
                    return

                if cli_result is None:
                    try:
                        cmux_api._v2_request("workspace.rename", {
                            "workspace_id": ws_uuid, "title": session_name,
                        })
                    except Exception:
                        pass
                    try:
                        cmux_api._v2_request("surface.send_text", {
                            "workspace_id": ws_uuid,
                            "text": f"cd {cwd} && {command}\n",
                        })
                    except Exception:
                        pass

                engine.ws_config.setdefault(ws_uuid, {})["customName"] = session_name
                engine._save_config()

                if prompt and ws_uuid:
                    def _deliver_prompt(workspace_uuid, text):
                        import re

                        repl_ready = re.compile(
                            r"(Model:|Cost:\s*\$\d|\u276f\s*$)",
                            re.MULTILINE | re.IGNORECASE,
                        )
                        for attempt in range(20):
                            time.sleep(2.5)
                            try:
                                screen = cmux_api.cmux_read_workspace(
                                    0, 0, lines=30, workspace_uuid=workspace_uuid,
                                )
                                matched = bool(screen and repl_ready.search(screen))
                                storage.debug_log({
                                    "event": "deliver_prompt_poll",
                                    "workspace_uuid": workspace_uuid,
                                    "attempt": attempt,
                                    "screen_len": len(screen) if screen else 0,
                                    "ready": matched,
                                })
                                if matched:
                                    ok = cmux_api.send_prompt_to_workspace(workspace_uuid, text)
                                    storage.debug_log({
                                        "event": "deliver_prompt_sent",
                                        "workspace_uuid": workspace_uuid,
                                        "ok": ok,
                                        "text_preview": text[:80],
                                    })
                                    if ok:
                                        return
                                    time.sleep(1.0)
                                    cmux_api.send_prompt_to_workspace(workspace_uuid, text)
                                    return
                            except Exception as exc:
                                storage.debug_log({
                                    "event": "deliver_prompt_error",
                                    "workspace_uuid": workspace_uuid,
                                    "attempt": attempt,
                                    "error": str(exc),
                                })

                    t = threading.Thread(
                        target=_deliver_prompt, args=(ws_uuid, prompt), daemon=True,
                    )
                    t.start()

                self._json_response({
                    "ok": True,
                    "workspace": {"index": ws_idx, "uuid": ws_uuid},
                    "worktreePath": cwd,
                    "branchName": branch_name,
                })
            elif self.path == "/api/git-stage":
                idx = data.get("index")
                file = data.get("file")
                if idx is None or not file:
                    self._json_response({"ok": False, "error": "index and file required"}, 400)
                    return
                cwd = engine._get_workspace_cwd(int(idx))
                if not cwd:
                    self._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
                    return
                result = engine._run_git_command(cwd, ["add", "--", file])
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/git-stage-path":
                cwd = self._resolve_git_path(data.get("path"))
                file = data.get("file")
                if not cwd or not file:
                    self._json_response({"ok": False, "error": "path and file required"}, 400)
                    return
                result = engine._run_git_command(cwd, ["add", "--", file])
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/git-unstage":
                idx = data.get("index")
                file = data.get("file")
                if idx is None or not file:
                    self._json_response({"ok": False, "error": "index and file required"}, 400)
                    return
                cwd = engine._get_workspace_cwd(int(idx))
                if not cwd:
                    self._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
                    return
                result = engine._run_git_command(cwd, ["reset", "HEAD", "--", file])
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/git-unstage-path":
                cwd = self._resolve_git_path(data.get("path"))
                file = data.get("file")
                if not cwd or not file:
                    self._json_response({"ok": False, "error": "path and file required"}, 400)
                    return
                result = engine._run_git_command(cwd, ["reset", "HEAD", "--", file])
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/git-open-file":
                idx = data.get("index")
                file = data.get("file")
                if idx is None or not file:
                    self._json_response({"ok": False, "error": "index and file required"}, 400)
                    return
                cwd = engine._get_workspace_cwd(int(idx))
                if not cwd:
                    self._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
                    return
                full_path = os.path.realpath(os.path.join(cwd, file))
                if not full_path.startswith(os.path.realpath(cwd)):
                    self._json_response({"ok": False, "error": "path outside workspace"}, 400)
                    return
                if not os.path.exists(full_path):
                    self._json_response({"ok": False, "error": "file not found"}, 404)
                    return
                try:
                    subprocess.Popen(["open", full_path])
                    self._json_response({"ok": True})
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
            elif self.path == "/api/open-in-native":
                file = data.get("file")
                cwd = self._resolve_git_path(data.get("cwd") or data.get("path")) if file else None
                if file:
                    full_path, error = self._resolve_workspace_file_path(cwd, file)
                    if error:
                        self._json_response({"ok": False, "error": error}, 404 if error.startswith("file not found") else 400)
                        return
                else:
                    full_path = os.path.realpath(os.path.expanduser(str(data.get("path") or "").strip()))
                    if not full_path:
                        self._json_response({"ok": False, "error": "path required"}, 400)
                        return
                    if not os.path.exists(full_path):
                        self._json_response({"ok": False, "error": f"file not found: {full_path}"}, 404)
                        return
                try:
                    subprocess.run(["open", full_path], check=True, capture_output=True, text=True)
                    self._json_response({"ok": True, "path": full_path})
                except (OSError, subprocess.CalledProcessError) as e:
                    self._json_response({"ok": False, "error": str(e), "path": full_path}, 500)
            elif self.path == "/api/git-diff":
                idx = data.get("index")
                file = data.get("file")
                section = data.get("section", "unstaged")
                if idx is None or not file:
                    self._json_response({"ok": False, "error": "index and file required"}, 400)
                    return
                cwd = engine._get_workspace_cwd(int(idx))
                if not cwd:
                    self._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
                    return
                full_path = os.path.join(cwd, file)
                if section == "untracked" and os.path.isdir(full_path):
                    parts = []
                    for root, _dirs, files in os.walk(full_path):
                        for fname in sorted(files):
                            fpath = os.path.relpath(os.path.join(root, fname), cwd)
                            part = engine._run_git_command(cwd, ["diff", "--no-index", "/dev/null", fpath], max_bytes=50 * 1024)
                            if not part.startswith("[error]"):
                                parts.append(part)
                    result = "\n".join(parts) if parts else "(empty directory)"
                else:
                    if section == "staged":
                        diff_args = ["diff", "--cached", "--", file]
                    elif section == "untracked":
                        diff_args = ["diff", "--no-index", "/dev/null", file]
                    else:
                        diff_args = ["diff", "--", file]
                    result = engine._run_git_command(cwd, diff_args, max_bytes=50 * 1024)
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True, "diff": result})
            elif self.path == "/api/git-diff-path":
                cwd = self._resolve_git_path(data.get("path"))
                file = data.get("file")
                section = data.get("section", "unstaged")
                if not cwd or not file:
                    self._json_response({"ok": False, "error": "path and file required"}, 400)
                    return
                full_path = os.path.join(cwd, file)
                if section == "untracked" and os.path.isdir(full_path):
                    parts = []
                    for root, _dirs, files in os.walk(full_path):
                        for fname in sorted(files):
                            fpath = os.path.relpath(os.path.join(root, fname), cwd)
                            part = engine._run_git_command(cwd, ["diff", "--no-index", "/dev/null", fpath], max_bytes=50 * 1024)
                            if not part.startswith("[error]"):
                                parts.append(part)
                    result = "\n".join(parts) if parts else "(empty directory)"
                else:
                    if section == "staged":
                        diff_args = ["diff", "--cached", "--", file]
                    elif section == "untracked":
                        diff_args = ["diff", "--no-index", "/dev/null", file]
                    else:
                        diff_args = ["diff", "--", file]
                    result = engine._run_git_command(cwd, diff_args, max_bytes=50 * 1024)
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True, "diff": result})
            elif self.path == "/api/file-content":
                cwd = self._resolve_git_path(data.get("path"))
                file = str(data.get("file") or "").strip()
                if not cwd or not file:
                    self._json_response({"ok": False, "error": "path and file required"}, 400)
                    return
                repo_root = os.path.realpath(cwd)
                full_path = os.path.realpath(os.path.join(repo_root, file))
                try:
                    if os.path.commonpath([repo_root, full_path]) != repo_root:
                        self._json_response({"ok": False, "error": "invalid file path"}, 400)
                        return
                except ValueError:
                    self._json_response({"ok": False, "error": "invalid file path"}, 400)
                    return
                if not os.path.isfile(full_path):
                    self._json_response({"ok": False, "error": "file not found"}, 404)
                    return
                try:
                    size = os.path.getsize(full_path)
                    if size > 500 * 1024:
                        self._json_response({"ok": False, "error": "file too large"}, 413)
                        return
                    with open(full_path, "r", encoding="utf-8") as handle:
                        content = handle.read()
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                self._json_response({"ok": True, "content": content})
            elif self.path == "/api/git-commit-files":
                cwd = self._resolve_git_path(data.get("path"))
                commit_hash = str(data.get("hash") or "").strip()
                if not cwd or not commit_hash:
                    self._json_response({"ok": False, "error": "path and hash required"}, 400)
                    return
                if not re.fullmatch(r"[0-9a-f]{4,40}", commit_hash, flags=re.IGNORECASE):
                    self._json_response({"ok": False, "error": "invalid hash"}, 400)
                    return
                result = engine._run_git_command(
                    cwd,
                    ["diff-tree", "--no-commit-id", "--name-status", "-r", commit_hash],
                )
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                files = []
                for line in result.splitlines():
                    parts = line.split("\t", 1)
                    if len(parts) != 2:
                        continue
                    status, file = parts
                    if status and file:
                        files.append({"status": status, "file": file})
                self._json_response({"ok": True, "files": files})
            elif self.path == "/api/git-commit-diff":
                cwd = self._resolve_git_path(data.get("path"))
                commit_hash = str(data.get("hash") or "").strip()
                file = str(data.get("file") or "").strip()
                if not cwd or not commit_hash or not file:
                    self._json_response({"ok": False, "error": "path, hash and file required"}, 400)
                    return
                if not re.fullmatch(r"[0-9a-f]{4,40}", commit_hash, flags=re.IGNORECASE):
                    self._json_response({"ok": False, "error": "invalid hash"}, 400)
                    return
                result = engine._run_git_command(
                    cwd,
                    ["diff", commit_hash + "~1", commit_hash, "--", file],
                    max_bytes=50 * 1024,
                )
                if result.startswith("[error]"):
                    result = engine._run_git_command(
                        cwd,
                        ["show", commit_hash, "--", file],
                        max_bytes=50 * 1024,
                    )
                if result.startswith("[error]"):
                    self._json_response({"ok": False, "error": result}, 500)
                    return
                self._json_response({"ok": True, "diff": result})
            elif path == "/api/hooks/pre-tool-use":
                hooks_routes.handle_pre_tool_use(self, data, engine=self.server.engine)
            else:
                self.send_error(404)

        def do_PATCH(self):
            path = urllib.parse.urlparse(self.path).path
            data = self._read_body()
            if path.startswith("/api/projects/"):
                project_id = urllib.parse.unquote(path[len("/api/projects/"):]).strip("/")
                project_routes.handle_patch_project(self, project_id, data)
                return
            if path.startswith("/api/objectives/"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                objective_routes.handle_patch_objective(self, objective_id, data)
                return
            if path.startswith("/api/workspaces/"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_patch_workspace(self, workspace_id, data)
                return
            self.send_error(404)

        def do_DELETE(self):
            path = urllib.parse.urlparse(self.path).path
            if path.startswith("/api/projects/"):
                project_id = urllib.parse.unquote(path[len("/api/projects/"):]).strip("/")
                project_routes.handle_delete_project(self, project_id)
                return
            if path.startswith("/api/objectives/") and "/action-buttons/" in path:
                parts = path.split("/")
                if len(parts) != 6 or parts[1] != "api" or parts[2] != "objectives" or parts[4] != "action-buttons":
                    self.send_error(404)
                    return
                objective_id = urllib.parse.unquote(parts[3])
                button_id = urllib.parse.unquote(parts[5])
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                action_buttons_routes.handle_delete_action_button(self, objective_id, objective, button_id)
                return
            if path.startswith("/api/workspaces/") and "/action-buttons/" in path:
                parts = path.split("/")
                if len(parts) != 6 or parts[1] != "api" or parts[2] != "workspaces" or parts[4] != "action-buttons":
                    self.send_error(404)
                    return
                workspace_id = urllib.parse.unquote(parts[3])
                button_id = urllib.parse.unquote(parts[5])
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                action_buttons_routes.handle_delete_workspace_action_button(self, workspace_id, workspace, button_id)
                return
            if path.startswith("/api/objectives/"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                objective_routes.handle_delete_objective(self, objective_id, engine=self.server.engine)
                return
            if path.startswith("/api/workspaces/"):
                workspace_id = urllib.parse.unquote(path[len("/api/workspaces/"):]).strip("/")
                workspace = workspaces.read_workspace_session(workspace_id)
                if workspace is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                workspace_routes.handle_delete_workspace(self, workspace_id, engine=self.server.engine)
                return
            self.send_error(404)

    return DashboardHandler
