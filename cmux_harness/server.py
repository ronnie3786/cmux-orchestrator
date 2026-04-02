import json
import os
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from . import cmux_api
from . import objectives
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
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path
            if path == "/":
                body = DASHBOARD_HTML.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif path == "/api/status":
                self._json_response(engine.get_status())
            elif path == "/api/log":
                self._json_response(engine.get_log())
            elif path.startswith("/api/git-status"):
                qs = parsed.query
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
            elif path.startswith("/api/screen"):
                qs = parsed.query
                params = urllib.parse.parse_qs(qs)
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
            elif path == "/api/objectives":
                self._json_response(objectives.list_objectives())
            elif path.startswith("/api/objectives/") and "/tasks/" in path and path.endswith("/screen"):
                parts = path.split("/")
                objective_id = parts[3]
                task_id = parts[5]
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "Not found"}, 404)
                    return
                task = next((t for t in objective.get("tasks", []) if t.get("id") == task_id), None)
                if not task or not task.get("workspaceId"):
                    self._json_response({"ok": False, "error": "Task not found"}, 404)
                    return
                try:
                    screen = cmux_api.cmux_read_workspace(
                        0, 0, lines=200, workspace_uuid=task["workspaceId"]
                    ) or ""
                except Exception:
                    screen = ""
                self._json_response({"ok": True, "screen": screen, "lines": 200})
            elif path.startswith("/api/objectives/") and "/messages" in path:
                objective_id = path.split("/")[3]
                params = urllib.parse.parse_qs(parsed.query)
                after = params.get("after", [None])[0]
                messages = self.server.engine.orchestrator.get_messages(objective_id, after=after)
                self._json_response(messages)
            elif path.startswith("/api/objectives/"):
                objective_id = urllib.parse.unquote(path[len("/api/objectives/"):]).strip("/")
                objective = objectives.read_objective(objective_id)
                if objective is None:
                    self._json_response({"ok": False, "error": "objective not found"}, 404)
                    return
                self._json_response(objective)
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
                    })
            elif path == "/api/models":
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
            path = urllib.parse.urlparse(self.path).path
            data = self._read_body()
            if path == "/api/toggle":
                engine.set_enabled(data.get("enabled", False))
                self._json_response({"ok": True, "enabled": engine.enabled})
            elif path.startswith("/api/objectives/") and path.endswith("/start"):
                objective_id = path.split("/")[3]
                started = self.server.engine.orchestrator.start_objective(objective_id)
                if started:
                    self._json_response({"ok": True, "status": "planning"})
                else:
                    self._json_response({"ok": False, "error": "Could not start objective"}, 400)
            elif path.startswith("/api/objectives/") and "/tasks/" in path and path.endswith("/approve"):
                parts = path.split("/")
                objective_id = parts[3]
                task_id = parts[5]
                action = data.get("action", "y\n")
                self.server.engine.orchestrator.handle_human_input(
                    objective_id,
                    f"Approved: {action}",
                    context={"task_id": task_id, "approval_action": action},
                )
                self._json_response({"ok": True})
            elif path.startswith("/api/objectives/") and path.endswith("/message"):
                objective_id = path.split("/")[3]
                message = data.get("message", "")
                context = data.get("context")
                self.server.engine.orchestrator.handle_human_input(objective_id, message, context)
                self._json_response({"ok": True})
            elif path == "/api/objectives":
                goal = data.get("goal", "")
                project_dir = data.get("projectDir", "")
                base_branch = data.get("baseBranch", "main")
                if not goal or not project_dir:
                    self._json_response({"ok": False, "error": "goal and projectDir required"}, 400)
                    return
                try:
                    objective = objectives.create_objective(goal, project_dir, base_branch=base_branch)
                except OSError as e:
                    self._json_response({"ok": False, "error": str(e)}, 500)
                    return
                self._json_response(objective, 201)
            elif path == "/api/workspace":
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
                with engine._lock:
                    self._json_response({
                        "ok": True,
                        "pollInterval": engine.poll_interval,
                        "model": engine.model,
                        "reviewEnabled": engine.review_enabled,
                        "reviewModel": engine.review_model,
                        "reviewBackend": engine.review_backend,
                    })
            elif path == "/api/rename":
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
            elif path == "/api/send":
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
                if ok:
                    # Clear "needs human" state so the badge resets
                    engine._append_log({
                        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "workspace": idx,
                        "workspaceName": ws.get("name", ws.get("surfaceLabel", "")),
                        "promptType": "manual",
                        "action": "user input",
                        "surfaceId": sid,
                    })
                    with engine._lock:
                        engine.fingerprints.pop(idx, None)
                self._json_response({"ok": ok})
            elif path.startswith("/api/reviews/") and path.endswith("/rerun"):
                session_id = urllib.parse.unquote(path[len("/api/reviews/"):-len("/rerun")]).rstrip("/")
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
            elif path.startswith("/api/reviews/") and path.endswith("/dismiss"):
                session_id = urllib.parse.unquote(path[len("/api/reviews/"):-len("/dismiss")]).rstrip("/")
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
            elif path == "/api/new-session":
                project_path = data.get("projectPath", "~/Documents/Development/Doximity-Claude")
                branch_name = data.get("branchName", "")
                jira_url = data.get("jiraUrl", "")
                prompt = data.get("prompt", "")
                command = data.get("command", "claude")

                # Expand ~ in project path
                project_path = os.path.expanduser(project_path)

                if not os.path.isdir(project_path):
                    self._json_response({"ok": False, "error": f"Project directory not found: {project_path}"}, 400)
                    return

                cwd = project_path
                session_name = branch_name or "New Session"

                # Create git worktree if branch name provided
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
                            # Branch already exists in git — try without -b to reuse it
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

                # Create cmux workspace
                ws_uuid = None
                ws_idx = None
                cli_result = None

                def _ws_ids(list_result):
                    """Return a set of workspace IDs from a workspace.list result."""
                    if not list_result:
                        return set()
                    ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                    return {w.get("id") or w.get("uuid") for w in ws_list if w.get("id") or w.get("uuid")}

                # Snapshot existing workspaces before creation so we can identify the new one
                pre_list = cmux_api._v2_request("workspace.list", {})
                existing_ids = _ws_ids(pre_list)

                try:
                    cli_args = ["cmux", "new-workspace", "--name", session_name]
                    if cwd:
                        cli_args += ["--cwd", cwd]
                    if command:
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

                # Resolve UUID + index: find the workspace that wasn't there before
                list_result = cmux_api._v2_request("workspace.list", {})
                if list_result:
                    ws_list = list_result if isinstance(list_result, list) else list_result.get("workspaces", [])
                    # Prefer a workspace whose ID is new (wasn't in pre-creation snapshot)
                    new_ws = next(
                        (w for w in ws_list if (w.get("id") or w.get("uuid")) not in existing_ids),
                        None,
                    )
                    # Fallback: find by matching session name
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

                # Save config
                engine.ws_config.setdefault(ws_uuid, {})["customName"] = session_name
                storage.save_config(engine.ws_config, engine.review_enabled, engine.review_model, engine.review_backend)

                # Deliver prompt in background — waits for Claude Code REPL to be ready
                if prompt and ws_uuid:
                    def _deliver_prompt(uuid, text):
                        """Poll for Claude Code REPL readiness, then inject prompt.

                        Uses cmux_api.send_prompt_to_workspace which mirrors WebMux's
                        sendPrompt() pattern: tmux paste-buffer (atomic) first, then
                        separate send_text + send_key("enter") fallback. Never embeds
                        \\n in the text — cmux does not interpret it as Enter.
                        """
                        import re
                        # Match Claude Code's status bar lines individually — they appear
                        # on separate lines so we can't use a single cross-line pattern.
                        # The REPL prompt char is ❯ (U+276F), not ASCII >.
                        # Cost can be $0.00 (2 decimal digits).
                        repl_ready = re.compile(
                            r"(Model:|Cost:\s*\$\d|\u276f\s*$)",
                            re.MULTILINE | re.IGNORECASE,
                        )
                        for attempt in range(20):  # up to ~50s
                            time.sleep(2.5)
                            try:
                                screen = cmux_api.cmux_read_workspace(
                                    0, 0, lines=30, workspace_uuid=uuid,
                                )
                                matched = bool(screen and repl_ready.search(screen))
                                storage.debug_log({
                                    "event": "deliver_prompt_poll",
                                    "workspace_uuid": uuid,
                                    "attempt": attempt,
                                    "screen_len": len(screen) if screen else 0,
                                    "ready": matched,
                                })
                                if matched:
                                    ok = cmux_api.send_prompt_to_workspace(uuid, text)
                                    storage.debug_log({
                                        "event": "deliver_prompt_sent",
                                        "workspace_uuid": uuid,
                                        "ok": ok,
                                        "text_preview": text[:80],
                                    })
                                    if ok:
                                        return
                                    # Send failed — wait and retry once
                                    time.sleep(1.0)
                                    cmux_api.send_prompt_to_workspace(uuid, text)
                                    return
                            except Exception as exc:
                                storage.debug_log({
                                    "event": "deliver_prompt_error",
                                    "workspace_uuid": uuid,
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
