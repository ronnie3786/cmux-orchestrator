import json
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from uuid import uuid4


DEMO_HOME_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>cmux Harness Demo Server</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; color: #162018; background: #f6f8f5; }
    main { max-width: 760px; margin: 0 auto; padding: 48px 24px; }
    h1 { font-size: 34px; margin: 0 0 12px; }
    p { color: #46524a; line-height: 1.5; }
    code { background: #e9eee8; padding: 2px 5px; border-radius: 4px; }
    .panel { background: white; border: 1px solid #dce3dc; border-radius: 8px; padding: 18px; margin-top: 20px; }
  </style>
</head>
<body>
  <main>
    <h1>cmux Harness Demo Server</h1>
    <p>This server provides public, disposable demo data for the iOS TestFlight review build.</p>
    <div class="panel">
      <p>Use this URL in the iOS app:</p>
      <p><code>{base_url}/harness</code></p>
    </div>
    <div class="panel">
      <p>Health check: <code>{base_url}/api/status</code></p>
      <p>Reset demo state: <code>POST {base_url}/api/demo/reset</code></p>
    </div>
  </main>
</body>
</html>
"""


class DemoHarness:
    """Stateful, contract-compatible demo backend for the iOS app.

    The live harness talks to cmux, git, Jira, and GitHub on the user's Mac.
    This class intentionally implements only the iOS-facing HTTP contract with
    disposable in-memory state so Apple review and external testers can exercise
    the app without access to a real developer machine.
    """

    def __init__(self):
        self._lock = threading.RLock()
        self._sessions = {}

    def handle_json(self, method, path, query="", headers=None, body=b""):
        api_path, namespace = self._api_path(path)
        if api_path is None:
            return 404, {"ok": False, "error": "not found"}

        data = self._decode_json(body)
        session = self._session(namespace)

        with self._lock:
            if method == "GET":
                return self._handle_get(session, api_path, query)
            if method == "POST":
                return self._handle_post(session, api_path, query, headers or {}, data, body)
            if method == "OPTIONS":
                return 204, {}
        return 405, {"ok": False, "error": "method not allowed"}

    def handle_html(self, host_url):
        base_url = host_url.rstrip("/")
        return DEMO_HOME_HTML.replace("{base_url}", base_url).encode("utf-8")

    def reset(self, namespace="default"):
        with self._lock:
            self._sessions[namespace or "default"] = DemoSessionState()

    def _session(self, namespace):
        key = namespace or "default"
        session = self._sessions.get(key)
        if session is None:
            session = DemoSessionState()
            self._sessions[key] = session
        return session

    def _handle_get(self, session, api_path, query):
        params = urllib.parse.parse_qs(query)

        if api_path == "/api/status":
            return 200, session.status()
        if api_path == "/api/log":
            return 200, session.log()
        if api_path == "/api/network":
            return 200, {
                "bonjourType": "_cmux-harness._tcp",
                "lanAddresses": [],
                "tailscaleHost": "",
                "tailscale": {"available": False, "savedHost": "", "activeHost": ""},
                "urls": {"home": "", "harness": "", "orchestrator": ""},
                "cmux": {
                    "socketFound": True,
                    "connected": True,
                    "workspaceCount": len(session.workspaces),
                    "staleData": False,
                },
            }
        if api_path == "/api/screen":
            index = _required_int(params, "index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            lines = _optional_int(params, "lines", 200)
            return session.screen(index=index, lines=min(lines, 500))
        if api_path == "/api/git-status":
            index = _required_int(params, "index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            return session.git_status(index=index)
        if api_path == "/api/github/pr-comments":
            index = _required_int(params, "index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            include_resolved = str(params.get("includeResolved", ["false"])[0]).lower() == "true"
            return 200, session.github_pr_comments(index=index, include_resolved=include_resolved)
        if api_path == "/api/skills":
            index = _required_int(params, "index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            return session.skills(index=index)
        if api_path == "/api/file-search":
            index = _required_int(params, "index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            query_text = params.get("q", [""])[0]
            return session.file_search(index=index, query=query_text)
        if api_path == "/api/jira/assigned":
            project = params.get("project", [None])[0]
            limit = _optional_int(params, "limit", 50)
            return 200, session.assigned_jira_tickets(project=project, limit=limit)
        if api_path == "/api/jira/issue":
            query_text = params.get("q", [""])[0]
            return session.jira_issue(query_text)

        return 404, {"ok": False, "error": "not found"}

    def _handle_post(self, session, api_path, query, headers, data, raw_body):
        if api_path == "/api/demo/reset":
            session.reset()
            return 200, {"ok": True}
        if api_path == "/api/toggle":
            enabled = bool(data.get("enabled"))
            session.enabled = enabled
            session.add_log(None, "Global auto mode changed", "configuration")
            return 200, {"ok": True, "enabled": enabled}
        if api_path == "/api/workspace":
            index = data.get("index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            mode = str(data.get("autoMode") or ("auto" if data.get("enabled") else "off"))
            return session.set_workspace_mode(int(index), mode)
        if api_path == "/api/workspace-star":
            index = data.get("index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            return session.set_workspace_starred(int(index), bool(data.get("starred")))
        if api_path == "/api/rename":
            index = data.get("index")
            if index is None:
                return 400, {"ok": False, "error": "index required"}
            return session.rename_workspace(int(index), str(data.get("name") or ""))
        if api_path == "/api/send":
            index = data.get("index")
            text = data.get("text")
            key = str(data.get("key") or "").strip().lower()
            if index is None or (not text and not key):
                return 400, {"ok": False, "error": "index and text or key required"}
            if key and key not in {"up", "down", "tab", "enter", "left", "right", "escape", "backspace"}:
                return 400, {"ok": False, "error": f"unsupported key: {key}"}
            return session.send(index=int(index), text=text, key=key)
        if api_path == "/api/new-session":
            return 200, session.new_session(data)
        if api_path == "/api/git-stage":
            return session.stage_file(int(data.get("index", -1)), str(data.get("file") or ""))
        if api_path == "/api/git-unstage":
            return session.unstage_file(int(data.get("index", -1)), str(data.get("file") or ""))
        if api_path == "/api/git-diff":
            return session.git_diff(
                int(data.get("index", -1)),
                str(data.get("file") or ""),
                str(data.get("section") or "unstaged"),
            )
        if api_path == "/api/attachments":
            workspace_index = headers.get("X-Cmux-Workspace-Index", "")
            workspace_uuid = headers.get("X-Cmux-Workspace-UUID", "")
            filename = urllib.parse.unquote(headers.get("X-Cmux-Filename", "") or "attachment.bin")
            content_type = headers.get("Content-Type", "application/octet-stream")
            return 200, session.upload_attachment(
                workspace_index=workspace_index,
                workspace_uuid=workspace_uuid,
                filename=filename,
                content_type=content_type,
                size=len(raw_body),
            )
        if api_path == "/api/push/register":
            return 200, {"ok": True}
        if api_path == "/api/push/clear":
            return 200, {"ok": True}

        return 404, {"ok": False, "error": "not found"}

    @staticmethod
    def _decode_json(body):
        if not body:
            return {}
        try:
            return json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    @staticmethod
    def _api_path(path):
        parsed_path = urllib.parse.unquote(path or "/")
        if parsed_path.startswith("/api/") or parsed_path == "/api":
            return parsed_path, "default"

        marker = "/api/"
        marker_index = parsed_path.find(marker)
        if marker_index < 0:
            return None, None

        namespace = parsed_path[:marker_index].strip("/") or "default"
        return parsed_path[marker_index:], namespace


class DemoSessionState:
    def __init__(self):
        self.reset()

    def reset(self):
        self.enabled = True
        self.started_at = time.time()
        self.next_index = 4
        self.attachments = []
        self.workspaces = [
            self._workspace(
                index=0,
                name="cmux Harness iOS",
                custom_name="Review landing polish",
                branch="feature/testflight-demo",
                cwd="/Users/demo/Code/cmux-harness",
                auto_mode="auto",
                starred=True,
                git_dirty=True,
                cost="$1.27",
                terminal=_terminal_review_polish(),
            ),
            self._workspace(
                index=1,
                name="cmux Harness API",
                custom_name="Mock API server",
                branch="feature/mock-api",
                cwd="/Users/demo/Code/cmux-harness",
                auto_mode="super",
                starred=False,
                git_dirty=True,
                cost="$0.84",
                terminal=_terminal_mock_server(),
            ),
            self._workspace(
                index=2,
                name="Example Mobile App",
                custom_name="Apple review checklist",
                branch="qa/apple-review",
                cwd="/Users/demo/Code/example-ios",
                auto_mode="off",
                starred=False,
                git_dirty=False,
                cost="$0.36",
                terminal=_terminal_needs_human(),
            ),
        ]
        self.git_state = {
            0: {
                "staged": [{"status": "M", "file": "cmux-harness-ios/Views/Root/ServerSetupViews.swift"}],
                "unstaged": [
                    {"status": "M", "file": "cmux-harness-ios/Feature/HarnessFeature.swift"},
                    {"status": "M", "file": "cmux-harness-ios/AppInfo.plist"},
                ],
                "untracked": ["docs/TESTFLIGHT_DEMO_REVIEW.md"],
            },
            1: {
                "staged": [],
                "unstaged": [
                    {"status": "M", "file": "cmux_harness/demo.py"},
                    {"status": "M", "file": "demo_dashboard.py"},
                ],
                "untracked": ["Dockerfile.demo"],
            },
            2: {"staged": [], "unstaged": [], "untracked": []},
        }
        self.log_entries = [
            self._log_entry(2, "Waiting for human input", "approval", "Confirm the simulated App Review notes look correct."),
            self._log_entry(1, "Auto-approved read-only inspection", "auto", "Review sandbox inspected fake git status."),
            self._log_entry(0, "Auto-approved safe edit", "auto", "Demo server button added to setup flow."),
        ]

    def status(self):
        return {
            "enabled": self.enabled,
            "workspaces": [self._public_workspace(workspace) for workspace in self.workspaces],
            "pollInterval": 2,
            "socketFound": True,
            "model": "demo-sonnet",
            "reviewEnabled": True,
            "reviewModel": "demo-reviewer",
            "reviewBackend": "mock",
            "contractReviewEnabled": True,
            "connected": True,
            "lastSuccessfulPoll": time.time(),
            "connectionLostAt": None,
            "staleData": False,
            "ollamaAvailable": True,
        }

    def log(self):
        return list(self.log_entries)

    def screen(self, index, lines):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        screen = _last_lines(workspace["screenFull"], lines)
        return 200, {"ok": True, "screen": screen, "lines": lines}

    def set_workspace_mode(self, index, mode):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        if mode not in {"off", "auto", "super"}:
            mode = "auto" if mode else "off"
        workspace["autoMode"] = mode
        workspace["enabled"] = mode != "off"
        if workspace["enabled"]:
            workspace["autoEnabledAt"] = time.time()
            workspace["autoExpiresAt"] = time.time() + 3600
        else:
            workspace["autoEnabledAt"] = None
            workspace["autoExpiresAt"] = None
        self.add_log(index, f"Workspace auto mode set to {mode}", "configuration")
        return 200, {"ok": True, "enabled": workspace["enabled"]}

    def set_workspace_starred(self, index, starred):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        workspace["starred"] = starred
        self.add_log(index, "Workspace starred" if starred else "Workspace unstarred", "manual")
        return 200, {"ok": True}

    def rename_workspace(self, index, name):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        workspace["customName"] = name.strip() or None
        self.add_log(index, "Workspace renamed", "manual")
        return 200, {"ok": True}

    def send(self, index, text=None, key=""):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}

        if key:
            user_line = f"$ <{key}>"
            response = self._response_for_key(key)
            prompt_type = "manual-key"
            action = "user key"
        else:
            clean_text = str(text or "").rstrip("\n")
            user_line = f"$ {clean_text}"
            response = self._response_for_text(clean_text)
            prompt_type = "manual"
            action = "user input"

        workspace["screenFull"] = "\n".join([workspace["screenFull"].rstrip(), user_line, response, "$ "])
        workspace["screenTail"] = _last_lines(workspace["screenFull"], 18)
        self.add_log(index, action, prompt_type, key=key or None)
        return 200, {"ok": True}

    def new_session(self, data):
        index = self.next_index
        self.next_index += 1

        mode_command = str(data.get("command") or "claude")
        branch = str(data.get("branchName") or "").strip() or f"demo-session-{index}"
        session_name = str(data.get("sessionName") or "").strip()
        prompt = str(data.get("prompt") or "").strip()
        jira_url = str(data.get("jiraUrl") or "").strip()
        display_name = session_name or branch.replace("-", " ").title()
        cwd = str(data.get("projectPath") or "/Users/demo/Code/cmux-harness")

        terminal = "\n".join([
            f"$ cd {cwd}",
            f"$ {mode_command}",
            "Starting simulated cmux session...",
            f"Session: {display_name}",
            f"Branch: {branch}",
            f"Jira: {jira_url or 'none'}",
            "",
            prompt or "Ready for review input.",
            "$ ",
        ])
        workspace = self._workspace(
            index=index,
            name=display_name,
            custom_name=display_name,
            branch=branch,
            cwd=cwd,
            auto_mode="off",
            starred=False,
            git_dirty=False,
            cost="$0.00",
            terminal=terminal,
        )
        self.workspaces.append(workspace)
        self.git_state[index] = {"staged": [], "unstaged": [], "untracked": []}
        self.add_log(index, "Created demo session", "manual")
        return {
            "ok": True,
            "workspace": {"index": index, "uuid": workspace["uuid"]},
            "worktreePath": cwd,
            "branchName": branch,
        }

    def git_status(self, index):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        state = self.git_state.get(index, {"staged": [], "unstaged": [], "untracked": []})
        return 200, {
            "ok": True,
            "branch": workspace.get("branch"),
            "cwd": workspace.get("cwd"),
            "staged": list(state["staged"]),
            "unstaged": list(state["unstaged"]),
            "untracked": list(state["untracked"]),
            "commits": [
                {"hash": "c8f3a21", "message": "Add TestFlight demo entry point"},
                {"hash": "4ad91be", "message": "Polish iOS session detail controls"},
                {"hash": "9b0210d", "message": "Document harness server onboarding"},
            ],
            "error": None,
        }

    def stage_file(self, index, file):
        state = self.git_state.get(index)
        if state is None:
            return 404, {"ok": False, "error": "workspace not found"}
        if not file:
            return 400, {"ok": False, "error": "file required"}
        state["unstaged"] = [entry for entry in state["unstaged"] if entry["file"] != file]
        state["untracked"] = [entry for entry in state["untracked"] if entry != file]
        if not any(entry["file"] == file for entry in state["staged"]):
            state["staged"].append({"status": "A", "file": file})
        self._mark_git_dirty(index)
        self.add_log(index, f"Staged {file}", "manual")
        return 200, {"ok": True}

    def unstage_file(self, index, file):
        state = self.git_state.get(index)
        if state is None:
            return 404, {"ok": False, "error": "workspace not found"}
        if not file:
            return 400, {"ok": False, "error": "file required"}
        removed = [entry for entry in state["staged"] if entry["file"] == file]
        state["staged"] = [entry for entry in state["staged"] if entry["file"] != file]
        if removed and not any(entry["file"] == file for entry in state["unstaged"]):
            state["unstaged"].append({"status": "M", "file": file})
        self._mark_git_dirty(index)
        self.add_log(index, f"Unstaged {file}", "manual")
        return 200, {"ok": True}

    def git_diff(self, index, file, section):
        if self._find_workspace(index) is None:
            return 404, {"ok": False, "error": "workspace not found"}
        if not file:
            return 400, {"ok": False, "error": "file required"}
        return 200, {
            "ok": True,
            "diff": _demo_diff(file=file, section=section),
            "error": None,
        }

    def github_pr_comments(self, index, include_resolved):
        workspace = self._find_workspace(index)
        if workspace is None:
            return {"ok": False, "error": "workspace not found"}
        threads = _pr_threads()
        visible_threads = threads if include_resolved else [thread for thread in threads if not thread["isResolved"]]
        files = {}
        for thread in visible_threads:
            files.setdefault(thread["path"], []).append(thread)
        return {
            "ok": True,
            "cwd": workspace.get("cwd"),
            "repository": {
                "owner": "ronnie3786",
                "name": "cmux-harness",
                "url": "https://github.com/ronnie3786/cmux-harness",
            },
            "pullRequest": {
                "number": 42,
                "title": "Prepare cmux Harness for external TestFlight",
                "url": "https://github.com/ronnie3786/cmux-harness/pull/42",
                "headRefName": workspace.get("branch"),
                "baseRefName": "main",
                "state": "OPEN",
                "author": "demo-reviewer",
            },
            "includeResolved": include_resolved,
            "threads": visible_threads,
            "files": [
                {"path": path, "threadCount": len(file_threads), "threads": file_threads}
                for path, file_threads in files.items()
            ],
            "totalThreadCount": len(threads),
            "returnedThreadCount": len(visible_threads),
            "resolvedThreadCount": len([thread for thread in threads if thread["isResolved"]]),
            "hiddenResolvedCount": 0 if include_resolved else len([thread for thread in threads if thread["isResolved"]]),
            "error": None,
        }

    def skills(self, index):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        return 200, {
            "ok": True,
            "rootPath": workspace.get("cwd"),
            "skillsDirectory": f"{workspace.get('cwd')}/.claude/skills",
            "userSkillsDirectory": "/Users/demo/.claude/skills",
            "projectSkills": [
                {"name": "ios-testflight-review", "skillFilePath": ".claude/skills/ios-testflight-review/SKILL.md", "scope": "project"},
                {"name": "swiftui-polish", "skillFilePath": ".claude/skills/swiftui-polish/SKILL.md", "scope": "project"},
            ],
            "userSkills": [
                {"name": "release-checklist", "skillFilePath": "/Users/demo/.claude/skills/release-checklist/SKILL.md", "scope": "user"},
                {"name": "bug-hunt", "skillFilePath": "/Users/demo/.claude/skills/bug-hunt/SKILL.md", "scope": "user"},
            ],
            "error": None,
        }

    def file_search(self, index, query):
        workspace = self._find_workspace(index)
        if workspace is None:
            return 404, {"ok": False, "error": "workspace not found"}
        files = [
            "cmux-harness-ios/cmux-harness-ios/Views/Root/ServerSetupViews.swift",
            "cmux-harness-ios/cmux-harness-ios/Feature/HarnessFeature.swift",
            "cmux-harness-ios/cmux-harness-ios/Infrastructure/API/HarnessAPI.swift",
            "cmux_harness/demo.py",
            "docs/TESTFLIGHT_DEMO_REVIEW.md",
            "README.md",
        ]
        needle = str(query or "").lower()
        matches = [path for path in files if not needle or needle in path.lower()]
        return 200, {
            "ok": True,
            "rootPath": workspace.get("cwd"),
            "query": query,
            "files": [{"path": path} for path in matches],
            "truncated": False,
            "limit": 50,
            "error": None,
        }

    def assigned_jira_tickets(self, project=None, limit=50):
        tickets = _jira_tickets()
        project_filter = str(project or "").strip().upper()
        if project_filter:
            tickets = [ticket for ticket in tickets if ticket["projectKey"] == project_filter]
        return {
            "ok": True,
            "project": project_filter or None,
            "projects": sorted({ticket["projectKey"] for ticket in tickets} or {"IOS", "HARNESS"}),
            "site": "https://demo.atlassian.example",
            "tickets": tickets[:limit],
            "error": None,
        }

    def jira_issue(self, query):
        normalized = str(query or "").strip().split("/")[-1].upper()
        for ticket in _jira_tickets():
            if ticket["key"] == normalized:
                return 200, {"ok": True, "site": "https://demo.atlassian.example", "ticket": ticket, "error": None}
        return 200, {
            "ok": True,
            "site": "https://demo.atlassian.example",
            "ticket": {
                "key": normalized or "HARNESS-101",
                "projectKey": (normalized.split("-", 1)[0] if "-" in normalized else "HARNESS"),
                "title": "Review generated demo ticket",
                "status": "In Review",
                "priority": "Medium",
                "issueType": "Task",
                "url": f"https://demo.atlassian.example/browse/{normalized or 'HARNESS-101'}",
            },
            "error": None,
        }

    def upload_attachment(self, workspace_index, workspace_uuid, filename, content_type, size):
        attachment = {
            "id": f"demo-attachment-{len(self.attachments) + 1}",
            "filename": filename,
            "originalFilename": filename,
            "contentType": content_type,
            "size": size,
            "path": f"/tmp/cmux-demo/{filename}",
            "workspaceKey": workspace_uuid or str(workspace_index),
            "createdAt": _iso_now(),
        }
        self.attachments.append(attachment)
        try:
            index = int(workspace_index)
        except (TypeError, ValueError):
            index = None
        self.add_log(index, f"Uploaded attachment {filename}", "manual")
        return {"ok": True, "attachment": attachment, "error": None}

    def add_log(self, index, action, prompt_type, reason=None, key=None):
        workspace = self._find_workspace(index) if index is not None else None
        self.log_entries.insert(0, self._log_entry(
            index,
            action,
            prompt_type,
            reason=reason,
            key=key,
            workspace=workspace,
        ))
        self.log_entries = self.log_entries[:200]

    def _workspace(self, index, name, custom_name, branch, cwd, auto_mode, starred, git_dirty, cost, terminal):
        workspace_uuid = str(uuid4()).upper()
        created_at = time.time() - (index + 1) * 720
        return {
            "hasClaude": True,
            "index": index,
            "name": name,
            "uuid": workspace_uuid,
            "enabled": auto_mode != "off",
            "autoMode": auto_mode,
            "starred": starred,
            "autoEnabledAt": created_at if auto_mode != "off" else None,
            "autoExpiresAt": created_at + 3600 if auto_mode != "off" else None,
            "customName": custom_name,
            "lastCheck": _iso_now(),
            "screenTail": _last_lines(terminal, 18),
            "screenFull": terminal,
            "cwd": cwd,
            "branch": branch,
            "sessionStart": created_at,
            "sessionCost": cost,
            "surfaceId": f"surface-{index}",
            "surfaceLabel": f"{name} : terminal",
            "surfaceTitle": name,
            "gitDirty": git_dirty,
            "surfaceCreatedAt": datetime.fromtimestamp(created_at, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "surfaceAge": max(0, time.time() - created_at),
        }

    def _public_workspace(self, workspace):
        public = dict(workspace)
        public["screenTail"] = _last_lines(workspace.get("screenFull", ""), 18)
        public["surfaceAge"] = max(0, time.time() - float(workspace.get("sessionStart") or time.time()))
        return public

    def _find_workspace(self, index):
        if index is None:
            return None
        for workspace in self.workspaces:
            if workspace["index"] == index:
                return workspace
        return None

    def _mark_git_dirty(self, index):
        workspace = self._find_workspace(index)
        if workspace:
            state = self.git_state.get(index, {})
            workspace["gitDirty"] = bool(state.get("staged") or state.get("unstaged") or state.get("untracked"))

    def _log_entry(self, index, action, prompt_type, reason=None, key=None, workspace=None):
        workspace = workspace if workspace is not None else self._find_workspace(index)
        return {
            "timestamp": _iso_now(),
            "workspace": index,
            "workspaceName": workspace.get("customName") or workspace.get("name") if workspace else None,
            "promptType": prompt_type,
            "action": action,
            "reason": reason,
            "key": key,
            "surfaceId": workspace.get("surfaceId") if workspace else None,
            "session_id": f"demo-session-{index}" if index is not None else "demo-global",
        }

    @staticmethod
    def _response_for_key(key):
        if key == "enter":
            return "Demo agent accepted the selection and continued the simulated workflow."
        if key in {"up", "down", "left", "right"}:
            return f"Moved simulated terminal selection {key}."
        if key == "escape":
            return "Dismissed the simulated terminal prompt."
        if key == "backspace":
            return "Deleted one simulated terminal character."
        if key == "tab":
            return "Completed the next simulated shell token."
        return "Handled simulated key input."

    @staticmethod
    def _response_for_text(text):
        lowered = text.lower()
        if "test" in lowered:
            return "\n".join([
                "Running simulated checks...",
                "PASS test_demo_server_contract",
                "PASS test_ios_demo_entry_point",
                "All demo checks passed.",
            ])
        if "apple" in lowered or "review" in lowered:
            return "Prepared a simulated App Review note with demo server instructions and public test data."
        if "diff" in lowered or "git" in lowered:
            return "Found 3 simulated changed files. Open the Git tab to stage, unstage, and inspect diffs."
        return "Demo agent received the message and updated this disposable session transcript."


def make_demo_handler(demo=None):
    demo = demo or DemoHarness()

    class DemoHandler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def do_OPTIONS(self):
            self._write_json({}, 204)

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if _is_demo_home_path(parsed.path):
                host = self.headers.get("Host", "localhost")
                scheme = "https" if self.headers.get("X-Forwarded-Proto") == "https" else "http"
                body = demo.handle_html(f"{scheme}://{host}{_home_prefix(parsed.path)}")
                self._write_bytes(body, "text/html; charset=utf-8")
                return
            status, payload = demo.handle_json("GET", parsed.path, parsed.query, dict(self.headers), b"")
            self._write_json(payload, status)

        def do_POST(self):
            parsed = urllib.parse.urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length else b""
            status, payload = demo.handle_json("POST", parsed.path, parsed.query, dict(self.headers), body)
            self._write_json(payload, status)

        def _write_json(self, payload, status=200):
            body = json.dumps(payload).encode("utf-8")
            self._write_bytes(body, "application/json", status)

        def _write_bytes(self, body, content_type, status=200):
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Cmux-Filename, X-Cmux-Workspace-Index, X-Cmux-Workspace-UUID")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                self.end_headers()
                if body:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                return False
            return True

    return DemoHandler


def _is_demo_home_path(path):
    trimmed = (path or "/").rstrip("/")
    return trimmed in {"", "/", "/harness"} or trimmed.endswith("/harness")


def _home_prefix(path):
    trimmed = (path or "/").rstrip("/")
    if trimmed.endswith("/harness"):
        trimmed = trimmed[:-len("/harness")]
    return trimmed if trimmed else ""


def _required_int(params, key):
    value = params.get(key, [None])[0]
    if value is None:
        return None
    return int(value)


def _optional_int(params, key, default):
    value = params.get(key, [None])[0]
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _last_lines(text, line_count):
    lines = str(text or "").splitlines()
    if line_count <= 0:
        return ""
    return "\n".join(lines[-line_count:])


def _terminal_review_polish():
    return """$ git status --short
 M cmux-harness-ios/cmux-harness-ios/Feature/HarnessFeature.swift
 M cmux-harness-ios/cmux-harness-ios/Views/Root/ServerSetupViews.swift
?? docs/TESTFLIGHT_DEMO_REVIEW.md

$ swift test --filter HarnessFeatureTests
Test Suite 'HarnessFeatureTests' passed

Agent: The iOS setup flow now has a review-safe demo path. Waiting for the final public URL before archive.
$ """


def _terminal_mock_server():
    return """$ python3 demo_dashboard.py 9097
cmux harness demo server: http://localhost:9097
Use in iOS: http://localhost:9097/harness

$ curl http://localhost:9097/api/status
{"enabled": true, "socketFound": true, "connected": true, "workspaces": 3}

Agent: The mock API supports mutable workspaces, fake git state, Jira lookup, file search, PR comments, and attachments.
$ """


def _terminal_needs_human():
    return """$ ./prepare-apple-review.sh
Collecting review notes...
Checking public demo server access...

Agent: I need confirmation before submitting external TestFlight review.
Question: Should the reviewer use the public demo server instead of a private Tailscale URL?
Options:
  1. Use public demo server
  2. Pause for manual backend setup
$ """


def _demo_diff(file, section):
    return f"""diff --git a/{file} b/{file}
index 1b2c3d4..5f6a7b8 100644
--- a/{file}
+++ b/{file}
@@ -8,6 +8,14 @@
 existing line
 existing line
+
+// Demo server change shown to TestFlight reviewers.
+let demoMode = true
+let demoSection = "{section}"
+
 existing line
 existing line
"""


def _pr_threads():
    return [
        {
            "id": "thread-demo-1",
            "path": "cmux-harness-ios/cmux-harness-ios/Views/Root/ServerSetupViews.swift",
            "line": 64,
            "originalLine": 64,
            "startLine": None,
            "originalStartLine": None,
            "diffSide": "RIGHT",
            "startDiffSide": "",
            "subjectType": "LINE",
            "isResolved": False,
            "isOutdated": False,
            "url": "https://github.com/ronnie3786/cmux-harness/pull/42#discussion_r1001",
            "codeContext": {
                "path": "cmux-harness-ios/cmux-harness-ios/Views/Root/ServerSetupViews.swift",
                "source": "demo",
                "startLine": 62,
                "endLine": 66,
                "lines": [
                    {"number": 62, "text": "Button {", "isTarget": False},
                    {"number": 63, "text": "    store.send(.useDemoServerTapped)", "isTarget": True},
                    {"number": 64, "text": "} label: {", "isTarget": False},
                ],
            },
            "comments": [
                {
                    "id": "comment-demo-1",
                    "author": "demo-reviewer",
                    "body": "Make sure this button uses a public HTTPS endpoint for the release archive.",
                    "bodyText": "Make sure this button uses a public HTTPS endpoint for the release archive.",
                    "createdAt": "2026-05-02T12:00:00Z",
                    "updatedAt": "2026-05-02T12:00:00Z",
                    "url": "https://github.com/ronnie3786/cmux-harness/pull/42#discussion_r1001",
                    "diffHunk": "@@ -62,3 +62,7 @@",
                    "path": "cmux-harness-ios/cmux-harness-ios/Views/Root/ServerSetupViews.swift",
                    "line": 64,
                    "originalLine": 64,
                }
            ],
        },
        {
            "id": "thread-demo-2",
            "path": "docs/TESTFLIGHT_DEMO_REVIEW.md",
            "line": 18,
            "originalLine": 18,
            "startLine": None,
            "originalStartLine": None,
            "diffSide": "RIGHT",
            "startDiffSide": "",
            "subjectType": "LINE",
            "isResolved": True,
            "isOutdated": False,
            "url": "https://github.com/ronnie3786/cmux-harness/pull/42#discussion_r1002",
            "codeContext": None,
            "comments": [
                {
                    "id": "comment-demo-2",
                    "author": "demo-reviewer",
                    "body": "Resolved: review notes include the demo path and no-login instructions.",
                    "bodyText": "Resolved: review notes include the demo path and no-login instructions.",
                    "createdAt": "2026-05-02T12:10:00Z",
                    "updatedAt": "2026-05-02T12:10:00Z",
                    "url": "https://github.com/ronnie3786/cmux-harness/pull/42#discussion_r1002",
                    "diffHunk": "@@ -18,1 +18,1 @@",
                    "path": "docs/TESTFLIGHT_DEMO_REVIEW.md",
                    "line": 18,
                    "originalLine": 18,
                }
            ],
        },
    ]


def _jira_tickets():
    return [
        {
            "key": "HARNESS-101",
            "projectKey": "HARNESS",
            "title": "Create public TestFlight demo backend",
            "status": "In Progress",
            "priority": "High",
            "issueType": "Story",
            "url": "https://demo.atlassian.example/browse/HARNESS-101",
        },
        {
            "key": "IOS-204",
            "projectKey": "IOS",
            "title": "Add demo server entry point to first-run setup",
            "status": "Ready for QA",
            "priority": "High",
            "issueType": "Task",
            "url": "https://demo.atlassian.example/browse/IOS-204",
        },
        {
            "key": "HARNESS-118",
            "projectKey": "HARNESS",
            "title": "Document Apple review instructions",
            "status": "Todo",
            "priority": "Medium",
            "issueType": "Task",
            "url": "https://demo.atlassian.example/browse/HARNESS-118",
        },
    ]
