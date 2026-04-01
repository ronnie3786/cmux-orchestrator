import json
import os
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from . import cmux_api
from . import storage
from . import review as review_mod
from .detection import OLLAMA_URL

_STATIC_DIR = Path(__file__).parent / "static"
_HTML_PATH = _STATIC_DIR / "dashboard.html"
try:
    DASHBOARD_HTML = _HTML_PATH.read_text(encoding="utf-8")
except FileNotFoundError:
    DASHBOARD_HTML = "<html><body><h1>dashboard.html not found</h1></body></html>"


def make_handler(engine):
    """Create a DashboardHandler class bound to the given engine instance."""

    class DashboardHandler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _json_response(self, data, status=200):
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_body(self):
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                return json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                return {}

        def do_GET(self):
            if self.path == "/":
                body = DASHBOARD_HTML.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif self.path == "/api/status":
                self._json_response(engine.get_status())
            elif self.path == "/api/log":
                self._json_response(engine.get_log())
            elif self.path.startswith("/api/git-status"):
                qs = urllib.parse.urlparse(self.path).query
                params = urllib.parse.parse_qs(qs)
                idx_str = params.get("index", [None])[0]
                if idx_str is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                result = engine.get_git_status(int(idx_str))
                if result is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                result["ok"] = True
                self._json_response(result)
            elif self.path == "/api/reviews":
                reviews = []
                for review in storage.list_reviews():
                    item = dict(review)
                    item["gitDiff"] = (item.get("gitDiff") or "")[:500]
                    reviews.append(item)
                self._json_response(reviews)
            elif self.path.startswith("/api/reviews/"):
                session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):])
                review = storage.get_review(session_id)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                self._json_response(review)
            elif self.path == "/api/config":
                with engine._lock:
                    self._json_response({
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                    })
            elif self.path == "/api/models":
                # Use cached availability — if already known unavailable, skip the connect attempt
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
            data = self._read_body()
            if self.path == "/api/toggle":
                engine.set_enabled(data.get("enabled", False))
                self._json_response({"ok": True, "enabled": engine.enabled})
            elif self.path == "/api/workspace":
                idx = data.get("index")
                enabled = data.get("enabled", True)
                if idx is not None:
                    idx = int(idx)
                    # For virtual indices, resolve to real index for config
                    with engine._lock:
                        virtual_ws = engine._build_virtual_workspaces()
                    vws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                    real_idx = vws.get("_real_index", idx) if vws else idx
                    engine.set_workspace_enabled(real_idx, enabled)
                self._json_response({"ok": True})
            elif self.path == "/api/config":
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
                with engine._lock:
                    self._json_response({
                        "ok": True,
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                    })
            elif self.path == "/api/rename":
                idx = data.get("index")
                name = data.get("name", "")
                if idx is None:
                    self._json_response({"ok": False, "error": "index required"}, 400)
                    return
                idx = int(idx)
                # For virtual indices, resolve to real index for rename
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                vws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                real_idx = vws.get("_real_index", idx) if vws else idx
                ok = engine.set_custom_name(real_idx, name)
                if not ok:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/send":
                idx = data.get("index")
                text = data.get("text", "")
                surface_id = data.get("surfaceId")
                if idx is None or not text:
                    self._json_response({"ok": False, "error": "index and text required"}, 400)
                    return
                idx = int(idx)
                # Look up in virtual workspaces to resolve surface_id for multi-surface
                with engine._lock:
                    virtual_ws = engine._build_virtual_workspaces()
                ws = next((w for w in virtual_ws if w.get("index", w.get("id")) == idx), None)
                if ws is None:
                    self._json_response({"ok": False, "error": "workspace not found"}, 404)
                    return
                sid = surface_id or ws.get("_surface_id")
                real_idx = ws.get("_real_index", idx)
                ok = cmux_api.cmux_send_to_workspace(real_idx, 0, text=text, workspace_uuid=ws.get("uuid"), surface_id=sid)
                self._json_response({"ok": ok})
            elif self.path.startswith("/api/reviews/") and self.path.endswith("/rerun"):
                session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):-len("/rerun")]).rstrip("/")
                path = storage.get_review_path(session_id)
                if path is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review = storage.read_review_file(path)
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
                    storage.write_review_file(path, review)
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                threading.Thread(
                    target=review_mod.run_review,
                    args=(path, engine.review_model, engine.review_backend, model_override, backend_override),
                    daemon=True,
                ).start()
                self._json_response({"ok": True})
            elif self.path.startswith("/api/reviews/") and self.path.endswith("/dismiss"):
                session_id = urllib.parse.unquote(self.path[len("/api/reviews/"):-len("/dismiss")]).rstrip("/")
                path = storage.get_review_path(session_id)
                if path is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review = storage.read_review_file(path)
                if review is None:
                    self._json_response({"ok": False, "error": "review not found"}, 404)
                    return
                review["reviewStatus"] = "dismissed"
                try:
                    storage.write_review_file(path, review)
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                self._json_response({"ok": True})
            elif self.path == "/api/new-session":
                cwd = data.get("cwd", "~/Documents/Development/Doximity-Cloud")
                command = data.get("command", "claude")

                # Step 1: Create workspace
                create_result = cmux_api._v2_request("workspace.create", {})
                if create_result is None:
                    self._json_response({"ok": False, "error": "Failed to create workspace"})
                    return

                # Step 2: Wait for initialization
                time.sleep(0.5)

                # Step 3: Resolve UUID — try create result first, then list
                ws_uuid = None
                ws_idx = None
                if isinstance(create_result, dict):
                    ws_uuid = (create_result.get("uuid") or
                               create_result.get("workspace_id") or
                               create_result.get("id"))
                    ws_idx = create_result.get("index")

                if not ws_uuid:
                    list_result = cmux_api._v2_request("workspace.list", {})
                    if list_result:
                        ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                        if ws_list:
                            newest = ws_list[-1]
                            ws_uuid = newest.get("uuid") or newest.get("id")
                            ws_idx = newest.get("index")

                if not ws_uuid:
                    self._json_response({"ok": False, "error": "Failed to get new workspace info"})
                    return

                # If index still unknown, refresh engine and look it up
                if ws_idx is None:
                    engine.refresh_workspaces()
                    with engine._lock:
                        for w in engine.workspaces:
                            if w.get("uuid") == ws_uuid:
                                ws_idx = w.get("index")
                                break

                # Step 4: cd to working directory (best-effort — don't abort on failure)
                try:
                    cmux_api._v2_request("surface.send_text", {
                        "workspace_id": ws_uuid,
                        "text": f"cd {cwd}\n",
                    })
                except Exception:
                    pass

                # Step 5: Brief pause before launching command
                time.sleep(0.3)

                # Step 6: Launch command (best-effort)
                try:
                    cmux_api._v2_request("surface.send_text", {
                        "workspace_id": ws_uuid,
                        "text": f"{command}\n",
                    })
                except Exception:
                    pass

                # Step 7: Return workspace info
                self._json_response({"ok": True, "workspace": {"index": ws_idx, "uuid": ws_uuid}})
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
                    # Directory: collect diffs for all files inside
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
            else:
                self.send_error(404)

    return DashboardHandler
