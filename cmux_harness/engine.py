import json
import logging
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone

from . import cmux_api
from . import detection
from . import review as review_mod
from . import storage


class HarnessEngine(threading.Thread):
    def __init__(self):
        super().__init__()
        self.daemon = True
        self.enabled = False
        self.workspace_enabled = {}
        self.poll_interval = 5
        self.approval_log = []
        self.workspaces = []
        self.fingerprints = {}
        self.screen_cache = {}   # idx -> last screen text (tail)
        self.ws_has_claude = {}  # idx -> bool (tracks active Claude sessions per workspace)
        self.idle_last_read = {} # idx -> float (timestamp of last screen read for idle workspaces)
        self.session_start = {}  # idx -> float (when hasClaude first went True)
        self.session_cost = {}   # idx -> str (parsed cost like "$0.45")
        self.session_ids = {}    # idx -> str (workspace UUID + session start timestamp)
        self.idle_miss_count = {} # idx -> int (consecutive polls where detect_claude_session returned False while previously active)
        self.surface_map = {}    # workspace_ref -> [{"ref", "title", "pane_ref"}, ...]
        self.surface_map_ts = 0  # timestamp of last cmux tree fetch
        self.socket_connected = False   # current socket connection state
        self.last_successful_poll = 0   # timestamp of last successful socket read
        self.connection_lost_at = 0     # when we first noticed the socket was gone
        self.consecutive_failures = 0   # count of consecutive failed polls
        self._lock = threading.Lock()
        self.model = detection.OLLAMA_MODEL
        self.review_enabled = True
        self.review_model = detection.OLLAMA_MODEL
        self.review_backend = "ollama"
        self.ollama_available = None   # None=unknown, True=available, False=unavailable
        self.ollama_last_check = 0     # timestamp of last Ollama health check
        self.ollama_retry_interval = 60  # seconds between retries after failure
        self._review_errors = {}
        self._review_models = {}
        self.branch_cache = {}        # uuid -> str (branch name)
        self.branch_cache_ts = {}     # uuid -> float (when branch was last resolved)
        self.terminal_metadata = {}   # surface_uuid -> metadata dict from debug.terminals
        self.terminal_metadata_ts = 0 # timestamp of last debug.terminals refresh
        config = storage.load_config()
        self.ws_config = config.get("workspaces", {})
        review_settings = config.get("reviewSettings", {})
        if isinstance(review_settings, dict):
            self.review_enabled = bool(review_settings.get("enabled", self.review_enabled))
            self.review_model = review_settings.get("model", self.review_model) or self.review_model
            self.review_backend = review_settings.get("backend", self.review_backend) or self.review_backend

    def _build_virtual_workspaces(self):
        """Expand workspaces into virtual entries, one per surface.
        Must be called with self._lock held.
        Single-surface workspaces emit as-is. Multi-surface workspaces
        produce one entry per surface with virtual indices."""
        result = []
        for ws in self.workspaces:
            idx = ws.get("index", ws.get("id"))
            surfaces = self.surface_map.get(idx, [])

            if len(surfaces) <= 1:
                # Single surface or no tree data — emit unchanged
                entry = dict(ws)
                entry["_surface_id"] = surfaces[0]["ref"] if surfaces else None
                entry["_surface_uuid"] = surfaces[0].get("id", "") if surfaces else ""
                entry["_surface_title"] = None
                entry["_surface_count"] = 1
                entry["_real_index"] = idx
                entry["_virtual"] = False
                result.append(entry)
            else:
                for ordinal, surf in enumerate(surfaces):
                    vidx = idx if ordinal == 0 else cmux_api.VIRTUAL_BASE + idx * cmux_api.VIRTUAL_STRIDE + ordinal
                    raw_title = surf.get("title", "").strip()
                    # Strip leading status chars (braille ⠂⠐, symbols ✳⠿, etc.)
                    clean_title = re.sub(r'^[\u2800-\u28FF\u2733\u2734\u2735\u25CF\u25CB\u2B24]\s*', '', raw_title).strip()
                    entry = dict(ws)
                    entry["index"] = vidx
                    entry["_real_index"] = idx
                    entry["_surface_id"] = surf["ref"]
                    entry["_surface_uuid"] = surf.get("id", "")
                    entry["_surface_title"] = clean_title or f"Pane {ordinal + 1}"
                    entry["_surface_count"] = len(surfaces)
                    entry["_virtual"] = (ordinal > 0)
                    result.append(entry)
        return result

    def _check_ollama(self):
        """Check if Ollama is reachable. Rate-limited to once per retry_interval."""
        now = time.time()
        with self._lock:
            if self.ollama_available is not None and (now - self.ollama_last_check) < self.ollama_retry_interval:
                return self.ollama_available
        try:
            import urllib.request
            with urllib.request.urlopen(f"{detection.OLLAMA_URL}/api/tags", timeout=3) as r:
                r.read()
            with self._lock:
                self.ollama_available = True
                self.ollama_last_check = now
            return True
        except Exception:
            with self._lock:
                if self.ollama_available is not False:
                    print("[harness] ⚠ Ollama unavailable, will retry every 60s")
                self.ollama_available = False
                self.ollama_last_check = now
            return False

    BRANCH_CACHE_TTL = 30  # seconds between branch re-checks per workspace

    def _resolve_branches(self):
        """Populate _branch for workspaces with a valid _cwd.
        Rate-limited per workspace via branch_cache_ts."""
        now = time.time()
        with self._lock:
            workspaces = list(self.workspaces)
        for ws in workspaces:
            uuid = ws.get("uuid", "")
            cwd = ws.get("_cwd", "")
            if not uuid or not cwd or not os.path.isdir(cwd):
                continue
            last_ts = self.branch_cache_ts.get(uuid, 0)
            if (now - last_ts) < self.BRANCH_CACHE_TTL:
                continue
            branch = self._run_git_command(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
            if branch.startswith("[error]"):
                branch = ""
            self.branch_cache[uuid] = branch
            self.branch_cache_ts[uuid] = now
        # Apply cached branches to workspace list
        with self._lock:
            for ws in self.workspaces:
                uuid = ws.get("uuid", "")
                if uuid and uuid in self.branch_cache:
                    ws["_branch"] = self.branch_cache[uuid]

    def set_enabled(self, val):
        with self._lock:
            self.enabled = bool(val)

    def set_workspace_enabled(self, index, val):
        with self._lock:
            self.workspace_enabled[index] = bool(val)
            # Persist by UUID so state survives index shifts
            ws_uuid = None
            for w in self.workspaces:
                if w.get("index", w.get("id")) == index:
                    ws_uuid = w.get("uuid")
                    break
            if ws_uuid:
                if ws_uuid not in self.ws_config:
                    self.ws_config[ws_uuid] = {}
                self.ws_config[ws_uuid]["autoEnabled"] = bool(val)
                storage.save_config(self.ws_config, self.review_enabled, self.review_model, self.review_backend)

    def set_poll_interval(self, val):
        with self._lock:
            self.poll_interval = max(2, min(30, int(val)))

    def set_model(self, name):
        with self._lock:
            self.model = name

    def set_review_config(self, enabled=None, model=None, backend=None):
        with self._lock:
            if enabled is not None:
                self.review_enabled = bool(enabled)
            if model is not None:
                self.review_model = str(model) or self.review_model
            if backend is not None:
                backend_name = str(backend).strip().lower()
                if backend_name in {"ollama", "lmstudio", "claude"}:
                    self.review_backend = backend_name
            storage.save_config(self.ws_config, self.review_enabled, self.review_model, self.review_backend)

    def set_custom_name(self, index, name):
        """Set a custom display name for the workspace at the given index.
        Persists to config keyed by UUID so it survives index shifts.
        Also renames the workspace in cmux so the sidebar stays in sync."""
        with self._lock:
            ws_uuid = None
            for w in self.workspaces:
                if w.get("index", w.get("id")) == index:
                    ws_uuid = w.get("uuid")
                    break
            if ws_uuid is None:
                return False
            if ws_uuid not in self.ws_config:
                self.ws_config[ws_uuid] = {}
            self.ws_config[ws_uuid]["customName"] = name
            storage.save_config(self.ws_config, self.review_enabled, self.review_model, self.review_backend)

        # Rename in cmux so the sidebar name stays in sync
        result = cmux_api._v2_request("workspace.rename", {"workspace_id": ws_uuid, "title": name})
        if result is None:
            logging.getLogger(__name__).warning("cmux rename failed for workspace %s", ws_uuid)
        return True

    def get_status(self):
        with self._lock:
            virtual_ws = self._build_virtual_workspaces()
            ws_list = []
            for ws in virtual_ws:
                idx = ws.get("index", ws.get("id"))
                uuid = ws.get("uuid", "")
                screen_tail = self.screen_cache.get(idx, "")
                lines = screen_tail.strip().splitlines() if screen_tail else []
                preview = "\n".join(lines[-25:]) if lines else ""
                has_claude = self.ws_has_claude.get(idx, False)
                cfg = self.ws_config.get(uuid, {})
                if "autoEnabled" in cfg:
                    enabled = cfg["autoEnabled"]
                else:
                    enabled = self.workspace_enabled.get(idx, False)
                # Build surface label for multi-surface workspaces
                surface_label = None
                surface_count = ws.get("_surface_count", 1)
                surface_title = ws.get("_surface_title")
                if surface_count > 1 and surface_title:
                    ws_display = cfg.get("customName") or ws.get("name", f"workspace-{idx}")
                    surface_label = f"{ws_display} : {surface_title}"
                # Enrich with terminal metadata from debug.terminals
                surface_uuid = ws.get("_surface_uuid", "")
                tmeta = self.terminal_metadata.get(surface_uuid, {})
                ws_list.append({
                    "hasClaude": has_claude,
                    "index": idx,
                    "name": ws.get("name", f"workspace-{idx}"),
                    "uuid": uuid,
                    "enabled": enabled,
                    "customName": cfg.get("customName"),
                    "lastCheck": ws.get("_lastCheck", ""),
                    "screenTail": preview,
                    "screenFull": screen_tail,
                    "cwd": ws.get("_cwd", ""),
                    "branch": ws.get("_branch", ""),
                    "sessionStart": self.session_start.get(idx, 0),
                    "sessionCost": self.session_cost.get(idx, ""),
                    "surfaceId": ws.get("_surface_id"),
                    "surfaceLabel": surface_label,
                    "surfaceTitle": tmeta.get("surface_title", ""),
                    "gitDirty": tmeta.get("git_dirty", False),
                    "surfaceCreatedAt": tmeta.get("surface_created_at", ""),
                    "surfaceAge": tmeta.get("runtime_surface_age_seconds", 0),
                })
            return {
                "enabled": self.enabled,
                "workspaces": ws_list,
                "pollInterval": self.poll_interval,
                "socketFound": cmux_api._find_socket_path() is not None,
                "model": self.model,
                "reviewEnabled": self.review_enabled,
                "reviewModel": self.review_model,
                "reviewBackend": self.review_backend,
                "connected": self.socket_connected,
                "lastSuccessfulPoll": self.last_successful_poll,
                "connectionLostAt": self.connection_lost_at,
                "staleData": not self.socket_connected,
                "ollamaAvailable": self.ollama_available,
            }

    def get_log(self, limit=200):
        with self._lock:
            return list(reversed(self.approval_log[-limit:]))

    def _append_log(self, entry):
        with self._lock:
            idx = entry.get("workspace")
            if idx is not None and "session_id" not in entry:
                session_id = self.session_ids.get(idx)
                if session_id:
                    entry["session_id"] = session_id
            self.approval_log.append(entry)
            if len(self.approval_log) > 500:
                self.approval_log = self.approval_log[-500:]
        try:
            with open(storage.LOG_FILE, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except OSError:
            pass
        self._log_write_count = getattr(self, "_log_write_count", 0) + 1
        if self._log_write_count % 100 == 0:
            storage.rotate_log_file(storage.LOG_FILE)
        ts = entry.get("timestamp", "")
        ws_name = entry.get("workspaceName", "?")
        ptype = entry.get("promptType", "?")
        action = entry.get("action", "?")
        print(f"[{ts}] approved ws={ws_name} type={ptype} action={action}")

    def _run_git_command(self, cwd, args, max_bytes=None):
        if not cwd:
            return ""
        try:
            if not os.path.isdir(cwd):
                return f"[error] cwd not found: {cwd}"
            result = subprocess.run(
                ["git"] + args,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except subprocess.TimeoutExpired:
            return f"[error] git {' '.join(args)} timed out after 10s"
        except OSError as e:
            return f"[error] git {' '.join(args)} failed: {e}"

        output = result.stdout or ""
        if result.returncode != 0:
            err = (result.stderr or "").strip()
            if err:
                output = err if not output.strip() else f"{output.rstrip()}\n{err}"
        if max_bytes is not None:
            raw = output.encode("utf-8", errors="replace")
            if len(raw) > max_bytes:
                marker = b"\n...[truncated]..."
                output = (raw[: max_bytes - len(marker)] + marker).decode("utf-8", errors="replace")
        return output.strip()

    def _get_workspace_cwd(self, ws_index):
        """Resolve the working directory for a workspace index."""
        with self._lock:
            virtual_ws = self._build_virtual_workspaces()
            ws = next((w for w in virtual_ws if w.get("index", w.get("id")) == ws_index), None)
        if ws is None:
            return None
        cwd = ws.get("_cwd", "")
        if not cwd:
            # Fetch from v2 workspace.list as fallback
            ws_uuid = ws.get("uuid", "")
            if ws_uuid:
                result = cmux_api._v2_request("workspace.list", {})
                if result:
                    ws_list = result if isinstance(result, list) else result.get("workspaces", [])
                    match = next((w for w in ws_list if w.get("id") == ws_uuid), None)
                    if match:
                        cwd = match.get("current_directory", "")
        if not cwd or not os.path.isdir(cwd):
            return None
        return cwd

    def get_git_status(self, ws_index):
        """Return parsed git status for a workspace's cwd."""
        with self._lock:
            virtual_ws = self._build_virtual_workspaces()
            ws = next((w for w in virtual_ws if w.get("index", w.get("id")) == ws_index), None)
        if ws is None:
            return None
        cwd = ws.get("_cwd", "")
        branch = ws.get("_branch", "")
        # Fetch cwd from v2 workspace.list if not cached
        if not cwd:
            ws_uuid = ws.get("uuid", "")
            if ws_uuid:
                result = cmux_api._v2_request("workspace.list", {})
                if result:
                    ws_list = result if isinstance(result, list) else result.get("workspaces", [])
                    match = next((w for w in ws_list if w.get("id") == ws_uuid), None)
                    if match:
                        cwd = match.get("current_directory", "")
        if not cwd or not os.path.isdir(cwd):
            return {"branch": branch, "cwd": cwd, "staged": [], "unstaged": [], "untracked": [], "commits": []}
        # Get branch from git if not known
        if not branch:
            branch = self._run_git_command(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
        # Run git status directly — _run_git_command's strip() destroys
        # the leading whitespace that porcelain format depends on.
        try:
            _gs = subprocess.run(["git", "status", "--porcelain=v1"], cwd=cwd, capture_output=True, text=True, timeout=10)
            raw = _gs.stdout or ""
        except (subprocess.TimeoutExpired, OSError):
            raw = ""
        staged, unstaged, untracked = [], [], []
        for line in raw.splitlines():
            if len(line) < 3:
                continue
            x, y, fpath = line[0], line[1], line[3:]
            if x == "?" and y == "?":
                # Expand untracked directories into individual files
                full = os.path.join(cwd, fpath)
                if fpath.endswith("/") or os.path.isdir(full):
                    for root, _dirs, fnames in os.walk(full):
                        for fn in sorted(fnames):
                            untracked.append(os.path.relpath(os.path.join(root, fn), cwd))
                else:
                    untracked.append(fpath)
            else:
                if x not in (" ", "?"):
                    staged.append({"status": x, "file": fpath})
                if y not in (" ", "?"):
                    unstaged.append({"status": y, "file": fpath})
        log_raw = self._run_git_command(cwd, ["log", "--oneline", "-3"])
        commits = []
        for line in log_raw.splitlines():
            if line.startswith("[error]"):
                break
            parts = line.split(" ", 1)
            if len(parts) == 2:
                commits.append({"hash": parts[0], "message": parts[1]})
        return {"branch": branch, "cwd": cwd, "staged": staged, "unstaged": unstaged, "untracked": untracked, "commits": commits}

    def _get_session_approval_log(self, idx, session_id, start_ts, end_ts):
        entries = []
        start_iso = datetime.fromtimestamp(start_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if start_ts else ""
        end_iso = datetime.fromtimestamp(end_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            with open(storage.LOG_FILE, "r") as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if entry.get("workspace") != idx:
                        continue
                    if session_id and entry.get("session_id") == session_id:
                        entries.append(entry)
                        continue
                    ts = entry.get("timestamp", "")
                    if start_iso and start_iso <= ts <= end_iso:
                        entries.append(entry)
        except FileNotFoundError:
            return []
        except OSError:
            return []
        return entries

    def _capture_completion_snapshot(self, snapshot):
        completed_at = datetime.now(timezone.utc)
        completed_ts = completed_at.timestamp()
        completed_iso = completed_at.isoformat()

        idx = snapshot.get("workspaceIndex")
        terminal_snapshot = snapshot.get("terminalSnapshot", "")
        final_cost = snapshot.get("finalCost", "")
        start_ts = snapshot.get("sessionStart", 0)
        session_id = snapshot.get("sessionId", "")
        workspace_uuid = snapshot.get("workspaceUuid", "")
        workspace_name = snapshot.get("workspaceName", f"workspace-{idx}")
        cwd = snapshot.get("cwd", "")
        branch = snapshot.get("branch", "")

        duration = max(0.0, completed_ts - start_ts) if start_ts else 0.0
        approval_entries = self._get_session_approval_log(idx, session_id, start_ts, completed_ts)
        review = {
            "sessionId": session_id,
            "workspaceIndex": idx,
            "workspaceUuid": workspace_uuid,
            "workspaceName": workspace_name,
            "completedAt": completed_iso,
            "duration": round(duration, 1),
            "finalCost": final_cost,
            "terminalSnapshot": terminal_snapshot,
            "gitDiffStat": self._run_git_command(cwd, ["diff", "--stat"]),
            "gitDiff": self._run_git_command(cwd, ["diff"], max_bytes=50 * 1024),
            "gitLog": self._run_git_command(cwd, ["log", "--oneline", "-5"]),
            "cwd": cwd,
            "branch": branch,
            "taskDescription": snapshot.get("taskDescription", ""),
            "approvalLog": approval_entries,
            "reviewStatus": "pending",
        }

        timestamp = completed_at.strftime("%Y%m%dT%H%M%SZ")
        file_uuid = workspace_uuid or f"workspace-{idx}"
        path = storage.REVIEWS_DIR / f"{file_uuid}_{timestamp}.json"
        try:
            storage.write_review_file(path, review)
            storage.debug_log({
                "event": "completion_snapshot_captured",
                "workspace": idx,
                "workspace_uuid": workspace_uuid,
                "session_id": session_id,
                "path": str(path),
            })
            with self._lock:
                review_enabled = self.review_enabled
            if review_enabled:
                review_mod.run_review(path, self.review_model, self.review_backend)
        except OSError as e:
            storage.debug_log({
                "event": "completion_snapshot_error",
                "workspace": idx,
                "workspace_uuid": workspace_uuid,
                "session_id": session_id,
                "error": str(e),
            })

    def _capture_completion_snapshot_async(self, ws, idx):
        with self._lock:
            # Look up in virtual workspaces first, fall back to real workspaces
            virtual_ws = self._build_virtual_workspaces()
            current_ws = next(
                (w for w in virtual_ws if w.get("index", w.get("id")) == idx),
                {},
            )
            if not current_ws:
                current_ws = next(
                    (w for w in self.workspaces if w.get("index", w.get("id")) == idx),
                    {},
                )
            screen = self.screen_cache.get(idx, "")
            surface_uuid = current_ws.get("_surface_uuid", "")
            tmeta = self.terminal_metadata.get(surface_uuid, {})
            snapshot = {
                "sessionId": self.session_ids.get(idx, ""),
                "workspaceIndex": idx,
                "workspaceUuid": current_ws.get("uuid", ws.get("uuid", "")),
                "workspaceName": current_ws.get("name", ws.get("name", f"workspace-{idx}")),
                "surfaceId": current_ws.get("_surface_id") or ws.get("_surface_id"),
                "sessionStart": self.session_start.get(idx, 0),
                "finalCost": self.session_cost.get(idx, ""),
                "terminalSnapshot": "\n".join(screen.splitlines()[-50:]) if screen else "",
                "cwd": current_ws.get("_cwd", ws.get("_cwd", "")),
                "branch": current_ws.get("_branch", ws.get("_branch", "")),
                "taskDescription": tmeta.get("surface_title", ""),
            }

        # Fresh extended scrollback read (outside the lock, before spawning thread)
        ws_uuid = snapshot["workspaceUuid"]
        sid = snapshot.get("surfaceId")
        real_idx = current_ws.get("_real_index", idx) if current_ws else idx
        if ws_uuid:
            extended = cmux_api.cmux_read_workspace(
                real_idx, 0, lines=200,
                workspace_uuid=ws_uuid, surface_id=sid
            )
            if extended:
                snapshot["terminalSnapshot"] = "\n".join(extended.splitlines()[-200:])

        threading.Thread(
            target=self._capture_completion_snapshot,
            args=(snapshot,),
            daemon=True,
        ).start()

    def refresh_workspaces(self):
        # Prefer v2 API — gives current_directory for each workspace
        result = cmux_api._v2_request("workspace.list", {})
        if result:
            ws_list = result if isinstance(result, list) else result.get("workspaces", [])
            if ws_list:
                workspaces = []
                for ws in ws_list:
                    ws_uuid = ws.get("id", "")
                    workspaces.append({
                        "index": ws.get("index", 0),
                        "uuid": ws_uuid,
                        "name": ws.get("title", f"workspace-{ws.get('index', 0)}"),
                        "selected": ws.get("selected", False),
                        "_cwd": ws.get("current_directory", ""),
                        "_branch": self.branch_cache.get(ws_uuid, ""),
                    })
                with self._lock:
                    self.workspaces = workspaces
                return True

        # Fallback to v1 plain text
        raw = cmux_api.cmux_command("list_workspaces")
        if raw is None:
            return False
        workspaces = []
        for line in raw.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            selected = line.startswith("*")
            line = line.lstrip("* ")
            parts = line.split(":", 1)
            if len(parts) < 2:
                continue
            try:
                idx = int(parts[0].strip())
            except ValueError:
                continue
            rest = parts[1].strip()
            rest_parts = rest.split(" ", 1)
            uuid = rest_parts[0] if rest_parts else ""
            name = rest_parts[1] if len(rest_parts) > 1 else f"workspace-{idx}"
            workspaces.append({
                "index": idx,
                "uuid": uuid,
                "name": name,
                "selected": selected,
            })
        if not workspaces:
            return False
        with self._lock:
            self.workspaces = workspaces
        return True

    def get_workspaces_needing_attention(self):
        """Check notifications to find workspaces with unread items.
        Returns a set of workspace UUIDs. Prefers v2 API, falls back to v1."""
        notifications = cmux_api.cmux_notifications()
        if notifications is not None:
            uuids = set()
            for notif in notifications:
                if not notif.get("is_read", True):
                    ws_id = notif.get("workspace_id", "")
                    if ws_id:
                        uuids.add(ws_id)
            return uuids
        # Fallback to v1 text parsing
        raw = cmux_api.cmux_command("list_notifications")
        if not raw or raw == "No notifications":
            return set()
        uuids_needing_attention = set()
        for line in raw.strip().split("\n"):
            parts = line.split("|")
            if len(parts) >= 4 and parts[3] == "unread":
                tab_uuid = parts[1]
                uuids_needing_attention.add(tab_uuid)
        return uuids_needing_attention

    def check_workspace(self, ws):
        idx = ws.get("index", ws.get("id"))
        ws_name = ws.get("name", f"workspace-{idx}")
        surface_id = ws.get("_surface_id")
        real_idx = ws.get("_real_index", idx)
        ws_uuid = ws.get("uuid", None)

        surface_index = 0

        # Skip workspaces with no terminal surface (e.g. browser-only)
        if ws_uuid and not surface_id:
            return

        screen = cmux_api.cmux_read_workspace(real_idx, surface_index, lines=40, workspace_uuid=ws_uuid, surface_id=surface_id)
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        with self._lock:
            for w in self.workspaces:
                if w.get("index", w.get("id")) == real_idx:
                    w["_lastCheck"] = now_str
                    break
            if screen:
                self.screen_cache[idx] = screen

        if not screen:
            storage.debug_log({"event": "empty_screen", "workspace": idx, "name": ws_name, "surface_id": surface_id})
            return

        fp = detection.fingerprint(screen)
        with self._lock:
            if self.fingerprints.get(idx) == fp:
                return

        result = detection.detect_prompt(screen, model=self.model, ollama_available_checker=self._check_ollama)
        screen_tail = "\n".join(screen.splitlines()[-15:])

        storage.debug_log({
            "event": "check",
            "workspace": idx,
            "name": ws_name,
            "surface": surface_index,
            "surface_id": surface_id,
            "screen_tail": screen_tail,
            "detect_result": list(result) if result else None,
        })

        # Store fingerprint so we don't re-process the same screen
        with self._lock:
            self.fingerprints[idx] = fp

        if result is None:
            return

        pattern_name, action = result

        if action == "skip":
            print(f"[harness] ⚠ ws:{idx} ({ws_name}) needs human input: {pattern_name}")
            storage.debug_log({
                "event": "needs_human",
                "workspace": idx,
                "name": ws_name,
                "pattern": pattern_name,
                "screen_tail": screen_tail,
            })
            self._append_log({
                "timestamp": now_str,
                "workspace": idx,
                "workspaceName": ws_name,
                "promptType": pattern_name,
                "action": "⚠ needs human",
                "surface": surface_index,
                "surfaceId": surface_id,
            })
            return

        if action == "enter":
            ok = cmux_api.cmux_send_to_workspace(real_idx, surface_index, key="enter", workspace_uuid=ws_uuid, surface_id=surface_id)
        else:
            ok = cmux_api.cmux_send_to_workspace(real_idx, surface_index, text="y", workspace_uuid=ws_uuid, surface_id=surface_id)

        storage.debug_log({
            "event": "approved",
            "workspace": idx,
            "name": ws_name,
            "pattern": pattern_name,
            "action_sent": "Enter" if action == "enter" else "y",
            "ok": ok,
            "screen_tail": screen_tail,
            "surface_id": surface_id,
        })

        if ok:
            with self._lock:
                self.fingerprints.pop(idx, None)
            print(f"[harness] ✓ ws:{idx} ({ws_name}) {pattern_name} → {'Enter' if action == 'enter' else 'y'}")
            self._append_log({
                "timestamp": now_str,
                "workspace": idx,
                "workspaceName": ws_name,
                "promptType": pattern_name,
                "action": f"sent {'Enter' if action == 'enter' else 'y'}",
                "surface": surface_index,
                "surfaceId": surface_id,
            })

    def run(self):
        while True:
            try:
                with self._lock:
                    enabled = self.enabled
                    interval = self.poll_interval
                    had_workspaces = len(self.workspaces) > 0
                    was_connected = self.socket_connected
                # Always refresh workspace list so the UI shows them
                # even before the global toggle is enabled.
                got_data = self.refresh_workspaces()

                now_ts = time.time()
                if got_data:
                    # Successful poll — reset failure counters
                    with self._lock:
                        self.last_successful_poll = now_ts
                        if not self.socket_connected:
                            # Reconnection event
                            if self.connection_lost_at:
                                print(f"[harness] ✓ cmux socket reconnected after {now_ts - self.connection_lost_at:.0f}s")
                            else:
                                print("[harness] ✓ cmux socket connected")
                            self.socket_connected = True
                            self.consecutive_failures = 0
                            # Clear stale state to force fresh detection
                            self.ws_has_claude = {}
                            self.screen_cache = {}
                            self.idle_miss_count = {}
                        else:
                            self.consecutive_failures = 0
                else:
                    # Failed poll
                    with self._lock:
                        if had_workspaces:
                            self.consecutive_failures += 1
                            if self.consecutive_failures >= 3 and self.socket_connected:
                                self.socket_connected = False
                                self.connection_lost_at = now_ts
                                print(f"[harness] ✗ cmux socket lost after {self.consecutive_failures} consecutive failures")

                # Refresh surface map periodically via v2 API (falls back to CLI)
                if got_data and (now_ts - self.surface_map_ts) > cmux_api.SURFACE_MAP_TTL:
                    new_map = cmux_api.cmux_tree()
                    if new_map is not None:
                        with self._lock:
                            self.surface_map = new_map
                            self.surface_map_ts = now_ts

                # Resolve git branches (per-workspace TTL inside method)
                if got_data:
                    self._resolve_branches()

                # Refresh terminal metadata (debug.terminals)
                TERMINAL_METADATA_TTL = 20
                if got_data and (now_ts - self.terminal_metadata_ts) > TERMINAL_METADATA_TTL:
                    metadata = cmux_api.cmux_debug_terminals()
                    if metadata is not None:
                        with self._lock:
                            self.terminal_metadata = metadata
                            self.terminal_metadata_ts = now_ts

                # Build virtual workspace list (one entry per surface)
                with self._lock:
                    virtual_ws = self._build_virtual_workspaces()

                # Read screens for ALL virtual workspaces so the UI has data.
                # Active (hasClaude=True) are read every cycle.
                # Idle are read at most once every 30 seconds.
                IDLE_READ_INTERVAL = 30  # seconds
                now_ts = time.time()
                active_vidxs = set()
                for vws in virtual_ws:
                    ws_uuid = vws.get("uuid", "")
                    vidx = vws.get("index", vws.get("id"))
                    real_idx = vws.get("_real_index", vidx)
                    surface_id = vws.get("_surface_id")
                    active_vidxs.add(vidx)
                    if not ws_uuid or not surface_id:
                        continue
                    with self._lock:
                        is_idle = not self.ws_has_claude.get(vidx, False)
                        last_read = self.idle_last_read.get(vidx, 0)
                    if is_idle and (now_ts - last_read) < IDLE_READ_INTERVAL:
                        continue
                    screen = cmux_api.cmux_read_workspace(real_idx, 0, lines=40, workspace_uuid=ws_uuid, surface_id=surface_id)
                    if screen:
                        has_claude = detection.detect_claude_session(screen)
                        cost = storage.parse_session_cost(screen)
                        should_capture_snapshot = False
                        # Hysteresis: require multiple consecutive non-detections
                        # before transitioning ACTIVE → IDLE. This prevents transient
                        # screen states (e.g. after /clear) from flipping status.
                        IDLE_MISS_THRESHOLD = 3  # consecutive misses before transition
                        with self._lock:
                            self.screen_cache[vidx] = screen
                            prev_has_claude = self.ws_has_claude.get(vidx, False)
                            if has_claude:
                                self.idle_miss_count.pop(vidx, None)
                            elif prev_has_claude and not has_claude:
                                miss = self.idle_miss_count.get(vidx, 0) + 1
                                self.idle_miss_count[vidx] = miss
                                if miss < IDLE_MISS_THRESHOLD:
                                    # Suppress transition — keep reporting as active
                                    has_claude = True
                            self.ws_has_claude[vidx] = has_claude
                            self.idle_last_read[vidx] = now_ts
                            if has_claude and not prev_has_claude:
                                start_ts = time.time()
                                self.session_start[vidx] = start_ts
                                sid_parts = [ws_uuid]
                                if surface_id:
                                    sid_parts.append(surface_id)
                                sid_parts.append(str(int(start_ts)))
                                self.session_ids[vidx] = "_".join(sid_parts)
                            elif not has_claude and prev_has_claude:
                                should_capture_snapshot = True
                                self.idle_miss_count.pop(vidx, None)
                            if has_claude and cost is not None:
                                self.session_cost[vidx] = cost
                        if should_capture_snapshot:
                            self._capture_completion_snapshot_async(vws, vidx)
                            with self._lock:
                                self.session_start.pop(vidx, None)
                                self.session_cost.pop(vidx, None)
                                self.session_ids.pop(vidx, None)
                    else:
                        with self._lock:
                            self.idle_last_read[vidx] = now_ts
                # Clean up stale virtual indices (surfaces that disappeared)
                with self._lock:
                    stale_keys = [k for k in list(self.ws_has_claude.keys())
                                  if k not in active_vidxs and self.ws_has_claude.get(k)]
                for sk in stale_keys:
                    self._capture_completion_snapshot_async({}, sk)
                    with self._lock:
                        self.ws_has_claude.pop(sk, None)
                        self.screen_cache.pop(sk, None)
                        self.session_start.pop(sk, None)
                        self.session_cost.pop(sk, None)
                        self.session_ids.pop(sk, None)
                        self.idle_last_read.pop(sk, None)
                        self.fingerprints.pop(sk, None)
                        self.idle_miss_count.pop(sk, None)

                if enabled:
                    # Check which workspaces have unread notifications
                    attention_uuids = self.get_workspaces_needing_attention()
                    known_uuids = {vws.get("uuid", "") for vws in virtual_ws}
                    filter_is_useful = not attention_uuids or bool(attention_uuids & known_uuids)

                    for vws in virtual_ws:
                        vidx = vws.get("index", vws.get("id"))
                        ws_uuid = vws.get("uuid", "")
                        with self._lock:
                            has_claude = self.ws_has_claude.get(vidx, False)
                            cfg = self.ws_config.get(ws_uuid, {})
                            if "autoEnabled" in cfg:
                                ws_on = cfg["autoEnabled"]
                            else:
                                ws_on = self.workspace_enabled.get(vidx, True)
                        if not ws_on:
                            continue
                        # Only check workspaces with an active Claude Code session
                        if not has_claude:
                            continue
                        if filter_is_useful and attention_uuids and ws_uuid not in attention_uuids:
                            continue
                        self.check_workspace(vws)
            except Exception as exc:
                print(f"[harness] error: {exc}")
            time.sleep(interval)
