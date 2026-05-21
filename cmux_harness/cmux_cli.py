from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import Any


DEFAULT_CMUX_CLI = "/Users/ronnierocha/projects/cmux/build/Build/Products/Release/cmux"

LAUNCH_COMMANDS = {
    "Empty shell": "",
    "Codex": "codex",
    "Claude Code": "claude",
    "OpenCode": "opencode",
}


class CmuxCliError(RuntimeError):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


class CmuxCli:
    def __init__(self, executable: str | None = None, *, timeout: int = 15):
        self.executable = executable or os.environ.get("CMUX_CLI_PATH") or DEFAULT_CMUX_CLI
        self.timeout = timeout

    def binary(self) -> str:
        if self.executable and Path(self.executable).exists():
            return self.executable
        found = shutil.which("cmux")
        return found or self.executable

    def run(self, args: list[str], *, timeout: int | None = None, check: bool = True) -> subprocess.CompletedProcess:
        try:
            result = subprocess.run(
                [self.binary(), *args],
                capture_output=True,
                text=True,
                timeout=timeout or self.timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise CmuxCliError("cmux CLI not found", 503) from exc
        except subprocess.TimeoutExpired as exc:
            raise CmuxCliError("cmux CLI request timed out", 504) from exc
        except OSError as exc:
            raise CmuxCliError(f"cmux CLI failed: {exc}", 500) from exc
        if check and result.returncode != 0:
            message = (result.stderr or result.stdout or "cmux CLI request failed").strip()
            raise CmuxCliError(message, 502)
        return result

    def list_sessions(self) -> list[dict[str, Any]]:
        if _fake_enabled():
            return _fake_sessions()
        result = self.run(["--id-format", "both", "tree", "--all", "--json"], timeout=8)
        try:
            payload = json.loads(result.stdout or "{}")
        except json.JSONDecodeError as exc:
            raise CmuxCliError("cmux tree returned invalid JSON", 502) from exc
        sessions = parse_tree_sessions(payload)
        return self._enrich_session_cwds(sessions)

    def _enrich_session_cwds(self, sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        missing_or_weak = [
            session for session in sessions
            if session.get("surfaceRef") and not _is_existing_dir(str(session.get("cwd") or ""))
        ]
        if not missing_or_weak:
            return sessions
        try:
            result = self.run(["top", "--all", "--processes", "--format", "tsv"], timeout=8, check=False)
        except CmuxCliError:
            return sessions
        surface_pids = parse_top_surface_processes(result.stdout or "")
        cwd_cache: dict[str, str] = {}
        for session in missing_or_weak:
            surface_ref = str(session.get("surfaceRef") or "")
            for pid in surface_pids.get(surface_ref, []):
                cwd = cwd_cache.get(pid)
                if cwd is None:
                    cwd = process_cwd(pid)
                    cwd_cache[pid] = cwd
                if _is_existing_dir(cwd):
                    session["cwd"] = cwd
                    break
        return sessions

    def read_session(self, workspace_id: str, surface_id: str = "", *, lines: int = 200) -> str:
        if not workspace_id:
            raise CmuxCliError("workspaceId required", 400)
        if _fake_enabled():
            return (
                "Welcome to Orchestrate AI Terminal\n"
                "Workspace: /workspaces/orchestrate-ai/services/api\n"
                "Branch: feature/rate-limit\n"
                "Session: api-rate-limit-debug\n"
                "CMUX: 2 sessions active\n"
                "--------------------------------------------------\n\n"
                "dev@orchestrate:~/services/api$ git status\n"
                "On branch feature/rate-limit\n"
                "Your branch is up to date with 'origin/feature/rate-limit'.\n\n"
                "Changes not staged for commit:\n"
                "  (use \"git add <file>...\" to update what will be committed)\n"
                "  (use \"git restore <file>...\" to discard changes in working directory)\n"
                "        modified:   src/middleware/rateLimit.ts\n"
                "        modified:   src/config/rateLimit.config.ts\n\n"
                "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n\n"
                "dev@orchestrate:~/services/api$ npm test -- --runTestsByPath src/middleware/rateLimit.test.ts\n\n"
                "> api@1.0.0 test\n"
                "> jest --runTestsByPath src/middleware/rateLimit.test.ts\n\n"
                "PASS src/middleware/rateLimit.test.ts\n"
                "  rate limit middleware\n"
                "    should allow requests under the limit (45 ms)\n"
                "    should block requests over the limit (32 ms)\n"
                "    should reset after window time (28 ms)\n"
                "    should return correct headers (18 ms)\n\n"
                "Test Suites: 1 passed, 1 total\n"
                "Tests:       4 passed, 4 total\n"
                "Snapshots:   0 total\n"
                "Time:        1.234 s, estimated 2 s\n"
                "Ran all test suites within paths \"src/middleware/rateLimit.test.ts\".\n\n"
                "dev@orchestrate:~/services/api$ \n"
            )
        args = ["read-screen", "--scrollback", "--lines", str(max(1, min(int(lines or 200), 2000))), "--workspace", workspace_id]
        if surface_id:
            args.extend(["--surface", surface_id])
        result = self.run(args, timeout=8)
        return result.stdout or ""

    def search_sessions(self, query: str) -> list[dict[str, Any]]:
        query = str(query or "").strip()
        if not query:
            raise CmuxCliError("query required", 400)
        if _fake_enabled():
            return [session for session in _fake_sessions() if query.casefold() in json.dumps(session).casefold()]
        result = self.run(["find-window", "--content", query], timeout=10, check=False)
        if result.returncode != 0:
            return []
        return parse_find_window_output(result.stdout)

    def create_session(self, *, title: str, cwd: str, launch_type: str = "Empty shell") -> dict[str, Any]:
        cwd = str(cwd or "").strip()
        if not cwd:
            raise CmuxCliError("cwd required", 400)
        if not os.path.isdir(os.path.expanduser(cwd)):
            raise CmuxCliError(f"cwd not found: {cwd}", 400)
        launch_type = str(launch_type or "Empty shell").strip()
        if launch_type not in LAUNCH_COMMANDS:
            raise CmuxCliError(f"unsupported launch type: {launch_type}", 400)
        if _fake_enabled():
            fake_id = f"fake-{uuid.uuid4().hex[:8]}"
            return {
                "workspaceId": fake_id,
                "workspaceIndex": None,
                "surfaceId": f"surface-{fake_id}",
                "title": str(title or "New Task"),
                "cwd": os.path.expanduser(cwd),
                "launchType": launch_type,
                "active": True,
                "raw": {"fake": True},
            }
        args = ["new-workspace", "--name", str(title or "New Task"), "--cwd", os.path.expanduser(cwd)]
        command = LAUNCH_COMMANDS[launch_type]
        if command:
            args.extend(["--command", command])
        result = self.run(["--id-format", "both", *args], timeout=15)
        session = parse_new_workspace_output(result.stdout)
        if not session.get("workspaceId"):
            session = self._find_created_session(str(title or "New Task")) or session
        session.setdefault("title", str(title or "New Task"))
        session.setdefault("cwd", os.path.expanduser(cwd))
        session.setdefault("launchType", launch_type)
        return session

    def send_text(self, workspace_id: str, text: str, *, surface_id: str = "") -> dict[str, Any]:
        if not workspace_id:
            raise CmuxCliError("workspaceId required", 400)
        if _fake_enabled():
            return {"ok": True, "fake": True}
        args = ["send", "--workspace", workspace_id]
        if surface_id:
            args.extend(["--surface", surface_id])
        args.append(str(text or ""))
        self.run(args, timeout=8)
        return {"ok": True}

    def send_key(self, workspace_id: str, key: str, *, surface_id: str = "") -> dict[str, Any]:
        if not workspace_id:
            raise CmuxCliError("workspaceId required", 400)
        if _fake_enabled():
            return {"ok": True, "fake": True}
        args = ["send-key", "--workspace", workspace_id]
        if surface_id:
            args.extend(["--surface", surface_id])
        args.append(str(key or "").lower())
        self.run(args, timeout=8)
        return {"ok": True}

    def _find_created_session(self, title: str) -> dict[str, Any] | None:
        title_key = str(title or "").strip().casefold()
        if not title_key:
            return None
        matches = [
            session for session in self.list_sessions()
            if str(session.get("title") or "").strip().casefold() == title_key
        ]
        if not matches:
            return None
        return sorted(matches, key=lambda item: item.get("workspaceIndex") or -1)[-1]

    def inspect_session(self, session: dict[str, Any], screen_text: str = "") -> dict[str, Any]:
        text = f"{session.get('title', '')} {session.get('runningKind', '')} {screen_text[:2000]}".lower()
        if "claude" in text or "claude code" in text:
            running = "Claude Code"
        elif "opencode" in text or "open code" in text:
            running = "OpenCode"
        elif "codex" in text:
            running = "Codex"
        else:
            running = "Shell"
        state = "idle"
        if re_search(r"\b(npm|yarn|pnpm|pytest|xcodebuild|swift\s+test|gradle|mvn|bundle\s+exec)\b", text):
            state = "running_tool"
        elif re_search(r"\b(error|failed|traceback|exception)\b", text):
            state = "error"
        elif re_search(r"\b(pass|passed|success|completed)\b", text):
            state = "completed_recently"
        return {
            "workspaceId": session.get("workspaceId", ""),
            "surfaceId": session.get("surfaceId", ""),
            "runningKind": running,
            "state": state,
            "active": bool(session.get("active", True)),
            "title": session.get("title", ""),
            "cwd": session.get("cwd", ""),
            "freshness": "live" if screen_text else "snapshot",
        }


def re_search(pattern: str, text: str) -> bool:
    return re.search(pattern, text, flags=re.IGNORECASE) is not None


def infer_cwd_from_titles(*titles: str) -> str:
    home = str(Path.home())
    candidates: list[str] = []
    for title in titles:
        text = str(title or "").strip()
        if not text:
            continue
        for value in _title_path_candidates(text, home):
            if value not in candidates:
                candidates.append(value)
    for candidate in candidates:
        expanded = os.path.expanduser(candidate)
        if os.path.isdir(expanded):
            return expanded
    return ""


def _title_path_candidates(title: str, home: str) -> list[str]:
    values: list[str] = []
    text = title.strip()
    if text.startswith("~/"):
        values.append(os.path.expanduser(text))
    if text.startswith("/"):
        values.append(text)
    for match in re.finditer(r"(?:…|\.{3})(/[^\s]+)", text):
        suffix = match.group(1)
        values.append(f"{home}{suffix}")
        if suffix.startswith("/Documents/Development/"):
            values.append(f"{home}{suffix}")
        if suffix.startswith("/.claude/") or suffix.startswith("/.codex/"):
            values.append(f"{home}{suffix}")
    if re.match(r"^[A-Za-z0-9_.-]+$", text):
        values.append(str(Path(home) / "Documents" / "Development" / text))
    return values


def _is_existing_dir(value: str) -> bool:
    return bool(value and os.path.isdir(os.path.expanduser(value)))


def parse_top_surface_processes(text: str) -> dict[str, list[str]]:
    surface_pids: dict[str, list[str]] = {}
    for line in str(text or "").splitlines():
        columns = line.split("\t")
        if len(columns) < 6:
            continue
        kind = columns[3]
        item_id = columns[4]
        parent = columns[5]
        if kind != "process" or not item_id.isdigit() or not parent.startswith("surface:"):
            continue
        surface_pids.setdefault(parent, []).append(item_id)
    return surface_pids


def process_cwd(pid: str) -> str:
    try:
        result = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=2, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    for line in (result.stdout or "").splitlines():
        if line.startswith("n/") or line.startswith("n~"):
            return line[1:].strip()
    return ""


def parse_tree_sessions(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        return []
    sessions: list[dict[str, Any]] = []
    for window in payload.get("windows", []) or []:
        if not isinstance(window, dict):
            continue
        for workspace in window.get("workspaces", []) or []:
            if not isinstance(workspace, dict):
                continue
            workspace_ref = str(workspace.get("ref") or "")
            workspace_id = str(workspace.get("uuid") or workspace.get("id") or workspace_ref)
            workspace_title = str(workspace.get("title") or workspace.get("name") or "")
            cwd = str(workspace.get("current_directory") or workspace.get("cwd") or "")
            workspace_index = workspace.get("index")
            panes = workspace.get("panes") if isinstance(workspace.get("panes"), list) else []
            if not panes and workspace_id:
                inferred_cwd = cwd or infer_cwd_from_titles(workspace_title)
                sessions.append({
                    "workspaceId": workspace_id,
                    "workspaceRef": workspace_ref,
                    "workspaceIndex": workspace_index,
                    "surfaceId": "",
                    "surfaceRef": "",
                    "paneId": "",
                    "title": workspace_title,
                    "cwd": inferred_cwd,
                    "active": True,
                    "runningKind": "",
                    "raw": workspace,
                })
                continue
            for pane in panes:
                if not isinstance(pane, dict):
                    continue
                pane_id = str(pane.get("id") or pane.get("ref") or "")
                surfaces = pane.get("surfaces") if isinstance(pane.get("surfaces"), list) else []
                for surface in surfaces:
                    if not isinstance(surface, dict):
                        continue
                    if str(surface.get("type") or "terminal") != "terminal":
                        continue
                    surface_id = str(surface.get("id") or surface.get("uuid") or surface.get("ref") or "")
                    surface_ref = str(surface.get("ref") or "")
                    surface_title = str(surface.get("title") or workspace_title)
                    inferred_cwd = cwd or infer_cwd_from_titles(surface_title, workspace_title)
                    sessions.append({
                        "workspaceId": workspace_id,
                        "workspaceRef": workspace_ref,
                        "workspaceIndex": workspace_index,
                        "surfaceId": surface_id or surface_ref,
                        "surfaceRef": surface_ref,
                        "paneId": pane_id,
                        "title": workspace_title or surface_title,
                        "surfaceTitle": surface_title,
                        "cwd": inferred_cwd,
                        "active": True,
                        "runningKind": "",
                        "raw": {"workspace": workspace, "pane": pane, "surface": surface},
                    })
    return sessions


def parse_new_workspace_output(text: str) -> dict[str, Any]:
    raw = str(text or "").strip()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        payload = {}
    if isinstance(payload, dict):
        workspace = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else payload
        return {
            "workspaceId": str(workspace.get("uuid") or workspace.get("id") or workspace.get("workspace_id") or ""),
            "workspaceIndex": workspace.get("index"),
            "surfaceId": str(workspace.get("surface_id") or workspace.get("surfaceId") or ""),
            "title": str(workspace.get("title") or workspace.get("name") or ""),
            "cwd": str(workspace.get("cwd") or workspace.get("current_directory") or ""),
            "raw": payload,
        }
    return {}


def parse_find_window_output(text: str) -> list[dict[str, Any]]:
    rows = []
    for line in str(text or "").splitlines():
        value = line.strip()
        if not value:
            continue
        rows.append({"line": value, "raw": value})
    return rows


def _fake_enabled() -> bool:
    return os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_CMUX", "").strip().lower() in {"1", "true", "yes", "on"}


def _fake_sessions() -> list[dict[str, Any]]:
    fake_root = os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_ROOT", "").strip()
    def fake_path(path: str) -> str:
        return path if not fake_root else str(Path(fake_root) / path.strip("/"))
    return [
        {
            "workspaceId": "api-rate-limit-debug",
            "workspaceIndex": 0,
            "surfaceId": "api-rate-limit-surface",
            "paneId": "pane:api",
            "title": "api-rate-limit-debug",
            "cwd": fake_path("services/api"),
            "active": True,
            "runningKind": "Shell",
            "raw": {"fake": True, "pid": 18421, "branch": "feature/rate-limit", "displayOrder": 10},
        },
        {
            "workspaceId": "audit-log-spike",
            "workspaceIndex": 1,
            "surfaceId": "audit-log-surface",
            "paneId": "pane:audit",
            "title": "audit-log-spike",
            "cwd": fake_path("services/audit"),
            "active": True,
            "runningKind": "Shell",
            "raw": {
                "fake": True,
                "pid": 18457,
                "branch": "spike/audit-log",
                "displayOrder": 2,
                "startedLabel": "3h ago",
                "state": "warn",
            },
        },
        {
            "workspaceId": "user-repo-refactor",
            "workspaceIndex": 2,
            "surfaceId": "user-repo-surface",
            "paneId": "pane:user",
            "title": "user-repo-refactor",
            "cwd": fake_path("libs/user-repo"),
            "active": True,
            "runningKind": "Shell",
            "raw": {
                "fake": True,
                "branch": "refactor/user-repo",
                "displayOrder": 3,
                "startedLabel": "5h ago",
                "state": "active",
            },
        },
        {
            "workspaceId": "orphan-api-rate-limit-debug",
            "workspaceIndex": 3,
            "surfaceId": "orphan-api-rate-limit-surface",
            "paneId": "pane:orphan-api",
            "title": "api-rate-limit-debug",
            "cwd": fake_path("services/api"),
            "active": True,
            "runningKind": "Shell",
            "raw": {
                "fake": True,
                "branch": "feature/rate-limit",
                "displayOrder": 1,
                "startedLabel": "2h ago",
                "state": "active",
            },
        },
        {
            "workspaceId": "onboarding-ui-experiment",
            "workspaceIndex": 4,
            "surfaceId": "onboarding-surface",
            "paneId": "pane:onboarding",
            "title": "onboarding-ui-experiment",
            "cwd": fake_path("apps/web"),
            "active": True,
            "runningKind": "Shell",
            "raw": {"fake": True, "branch": "exp/onboarding-ui", "displayOrder": 40},
        },
        {
            "workspaceId": "orphan-onboarding-ui-experiment",
            "workspaceIndex": 5,
            "surfaceId": "orphan-onboarding-surface",
            "paneId": "pane:orphan-onboarding",
            "title": "onboarding-ui-experiment",
            "cwd": fake_path("apps/web"),
            "active": True,
            "runningKind": "Shell",
            "raw": {
                "fake": True,
                "branch": "exp/onboarding-ui",
                "displayOrder": 4,
                "startedLabel": "1d ago",
                "state": "idle",
            },
        },
    ]


_default_cli: CmuxCli | None = None


def get_cli() -> CmuxCli:
    global _default_cli
    if _default_cli is None:
        _default_cli = CmuxCli()
    return _default_cli
