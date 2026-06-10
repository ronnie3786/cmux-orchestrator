from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any


_PATH_PARAM_RE = re.compile(r"{([^}]+)}")


def parameter(
    name: str,
    *,
    location: str = "body",
    type: str = "string",
    required: bool = False,
    default: Any = None,
    enum: list[str] | None = None,
    description: str = "",
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "name": name,
        "in": location,
        "type": type,
        "required": required,
        "description": description,
    }
    if default is not None:
        item["default"] = default
    if enum:
        item["enum"] = enum
    return item


def endpoint(
    method: str,
    path: str,
    summary: str,
    *,
    category: str,
    safety: str = "read",
    parameters: list[dict[str, Any]] | None = None,
    request: dict[str, Any] | None = None,
    response: dict[str, Any] | None = None,
    examples: list[dict[str, Any]] | None = None,
    related_tools: list[str] | None = None,
    notes: str = "",
) -> dict[str, Any]:
    method = method.upper()
    params = list(parameters or [])
    existing = {(item.get("in"), item.get("name")) for item in params}
    for name in _PATH_PARAM_RE.findall(path):
        key = ("path", name)
        if key not in existing:
            params.insert(0, parameter(name, location="path", required=True, description=f"{name} path segment."))
            existing.add(key)
    item: dict[str, Any] = {
        "id": f"{method} {path}",
        "method": method,
        "path": path,
        "summary": summary,
        "category": category,
        "safety": safety,
        "parameters": params,
    }
    if request:
        item["request"] = request
    if response:
        item["response"] = response
    if examples:
        item["examples"] = examples
    if related_tools:
        item["relatedTools"] = related_tools
    if notes:
        item["notes"] = notes
    return item


def body_schema(required: list[str] | None = None, optional: list[str] | None = None, example: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "contentType": "application/json",
        "required": required or [],
        "optional": optional or [],
        "example": example or {},
    }


def discovery_payload(
    *,
    method: str = "",
    category: str = "",
    q: str = "",
    path_prefix: str = "",
    agent_tool_specs: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    endpoints = [dict(item) for item in ENDPOINTS]
    filtered = _filter_endpoints(endpoints, method=method, category=category, q=q, path_prefix=path_prefix)
    tools = _agent_tools(agent_tool_specs or {})
    return {
        "ok": True,
        "name": "cmux-harness API discovery",
        "description": "Machine-readable help for harness HTTP endpoints and Orchestrator V2 agent tools.",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "catalogVersion": 1,
        "discoveryEndpoints": [
            "GET /api/discovery",
            "GET /api/help",
        ],
        "usage": {
            "filters": {
                "method": "Optional HTTP method, e.g. GET or POST.",
                "category": "Optional category name from categories[].",
                "q": "Optional case-insensitive search over id, path, summary, category, safety, and related tool names.",
                "prefix": "Optional path prefix filter, e.g. /api/orchestrator-v2/pr-reviews.",
            },
            "agentToolInvocation": {
                "endpoint": "POST /api/orchestrator-v2/agent/tools/{toolName}",
                "body": {"runId": "optional-stable-run-id", "args": {"tool-specific": "arguments"}},
            },
        },
        "filters": {
            "method": method,
            "category": category,
            "q": q,
            "prefix": path_prefix,
        },
        "categories": sorted({item["category"] for item in ENDPOINTS}),
        "endpointCount": len(filtered),
        "totalEndpointCount": len(ENDPOINTS),
        "endpoints": filtered,
        "agentToolCount": len(tools),
        "agentTools": tools,
    }


def _filter_endpoints(
    endpoints: list[dict[str, Any]],
    *,
    method: str,
    category: str,
    q: str,
    path_prefix: str,
) -> list[dict[str, Any]]:
    method_key = str(method or "").strip().upper()
    category_key = str(category or "").strip().casefold()
    query = str(q or "").strip().casefold()
    prefix = str(path_prefix or "").strip()

    result = []
    for item in endpoints:
        if method_key and item["method"] != method_key:
            continue
        if category_key and item["category"].casefold() != category_key:
            continue
        if prefix and not item["path"].startswith(prefix):
            continue
        if query:
            haystack = " ".join(
                [
                    str(item.get("id") or ""),
                    str(item.get("path") or ""),
                    str(item.get("summary") or ""),
                    str(item.get("category") or ""),
                    str(item.get("safety") or ""),
                    " ".join(item.get("relatedTools") or []),
                ]
            ).casefold()
            if query not in haystack:
                continue
        result.append(item)
    return result


def _agent_tools(specs: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    tools = []
    for name, spec in sorted(specs.items()):
        item: dict[str, Any] = {
            "name": name,
            "status": spec.get("status", ""),
            "kind": spec.get("kind", ""),
            "requiresApproval": bool(spec.get("requiresApproval")),
            "invoke": {
                "method": "POST",
                "path": f"/api/orchestrator-v2/agent/tools/{name}",
                "body": {"runId": "optional-run-id", "args": {}},
            },
        }
        if name in TOOL_ARGUMENTS:
            item["arguments"] = TOOL_ARGUMENTS[name]
            item["invoke"]["body"]["args"] = TOOL_ARGUMENTS[name].get("example", {})
        tools.append(item)
    return tools


TOOL_ARGUMENTS: dict[str, dict[str, Any]] = {
    "list_pr_review_requests": {
        "required": [],
        "optional": ["repo", "limit"],
        "example": {"repo": "doximity/iOS-Doximity", "limit": 20},
    },
    "start_pr_review": {
        "required": ["number"],
        "optional": ["repo", "projectDir", "reviewCli", "pullRequest", "taskId", "title", "priority", "tags"],
        "example": {"repo": "doximity/iOS-Doximity", "number": 11244, "reviewCli": "codex"},
    },
    "create_cmux_session": {
        "required": ["workspaceDir"],
        "optional": ["title", "launchType"],
        "example": {"title": "New Session", "workspaceDir": "/Users/ronnierocha/Documents/Development/project", "launchType": "Codex"},
    },
    "send_cmux_prompt": {
        "required": ["workspaceId", "prompt"],
        "optional": ["surfaceId"],
        "example": {"workspaceId": "workspace-uuid", "surfaceId": "surface-uuid", "prompt": "Continue.\n"},
    },
}


ENDPOINTS: list[dict[str, Any]] = [
    endpoint("GET", "/api/discovery", "Discover harness HTTP endpoints and Orchestrator V2 agent tools.", category="Discovery", parameters=[
        parameter("method", location="query", description="Filter by HTTP method."),
        parameter("category", location="query", description="Filter by category."),
        parameter("q", location="query", description="Search endpoint help text."),
        parameter("prefix", location="query", description="Filter by path prefix."),
    ]),
    endpoint("GET", "/api/help", "Alias for /api/discovery.", category="Discovery"),

    endpoint("GET", "/api/network", "Return network URLs, Tailscale state, cmux state, and local CLI requirements.", category="Health"),
    endpoint("POST", "/api/network", "Save network settings such as a Tailscale host.", category="Health", safety="local_write", request=body_schema(optional=["tailscaleHost"], example={"tailscaleHost": "macbook.example.ts.net"})),
    endpoint("GET", "/api/status", "Return current harness engine status.", category="Health"),
    endpoint("GET", "/api/log", "Return harness event log entries.", category="Health"),
    endpoint("GET", "/api/feed", "Read cmux feed items.", category="Cmux"),
    endpoint("POST", "/api/feed/reply", "Reply to a cmux feed request.", category="Cmux", safety="terminal_write", request=body_schema(required=["requestId", "action"], optional=["kind", "mode", "selections"], example={"requestId": "request-id", "action": "approve"})),
    endpoint("GET", "/api/config", "Read harness configuration.", category="Config"),
    endpoint("POST", "/api/config", "Update harness configuration.", category="Config", safety="local_write", request=body_schema(optional=["pollInterval", "model", "reviewEnabled", "reviewModel", "reviewBackend", "contractReviewEnabled", "approvalThreshold", "defaultProjectDir", "defaultBaseBranch"], example={"pollInterval": 3, "reviewEnabled": True})),
    endpoint("GET", "/api/models", "List available local/review models.", category="Config"),
    endpoint("POST", "/api/toggle", "Enable or disable the harness engine.", category="Config", safety="local_write", request=body_schema(required=["enabled"], example={"enabled": True})),
    endpoint("GET", "/api/auto-policy-costs", "Return auto-policy cost dashboard data.", category="Config", parameters=[parameter("limit", location="query", type="integer", default=200)]),

    endpoint("GET", "/api/projects", "List configured projects.", category="Projects"),
    endpoint("POST", "/api/projects", "Create a project.", category="Projects", safety="local_write", request=body_schema(required=["name", "rootPath"], optional=["defaultBaseBranch"], example={"name": "iOS Doximity", "rootPath": "/Users/ronnierocha/Documents/Development/Doximity-Claude"})),
    endpoint("GET", "/api/projects/{projectId}", "Read one project.", category="Projects"),
    endpoint("PATCH", "/api/projects/{projectId}", "Update one project.", category="Projects", safety="local_write"),
    endpoint("DELETE", "/api/projects/{projectId}", "Delete one project.", category="Projects", safety="local_write"),
    endpoint("POST", "/api/projects/pick-root", "Open native folder picker for a project root.", category="Projects", safety="native_ui"),

    endpoint("GET", "/api/objectives", "List legacy objectives.", category="Objectives"),
    endpoint("POST", "/api/objectives", "Create a legacy objective.", category="Objectives", safety="local_write"),
    endpoint("GET", "/api/objectives/{objectiveId}", "Read a legacy objective.", category="Objectives"),
    endpoint("PATCH", "/api/objectives/{objectiveId}", "Update a legacy objective.", category="Objectives", safety="local_write"),
    endpoint("DELETE", "/api/objectives/{objectiveId}", "Delete a legacy objective.", category="Objectives", safety="local_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/start", "Start a legacy objective session.", category="Objectives", safety="terminal_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/message", "Send input to a legacy objective.", category="Objectives", safety="terminal_write"),
    endpoint("GET", "/api/objectives/{objectiveId}/messages", "Read objective messages.", category="Objectives"),
    endpoint("GET", "/api/objectives/{objectiveId}/screen", "Read objective screen output.", category="Objectives"),
    endpoint("GET", "/api/objectives/{objectiveId}/tasks/{taskId}/screen", "Read task screen output.", category="Objectives"),
    endpoint("POST", "/api/objectives/{objectiveId}/tasks/{taskId}/approve", "Approve a task step.", category="Objectives", safety="terminal_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/approve-hook", "Approve a hook request.", category="Objectives", safety="terminal_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/approve-plan", "Approve an objective plan.", category="Objectives", safety="terminal_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/approve-contracts", "Approve objective contracts.", category="Objectives", safety="terminal_write"),
    endpoint("GET", "/api/objectives/{objectiveId}/debug", "Read objective debug logs.", category="Objectives"),
    endpoint("GET", "/api/objectives/{objectiveId}/build-log", "Read objective build log.", category="Logs"),
    endpoint("GET", "/api/objectives/{objectiveId}/console-logs", "Read objective console logs.", category="Logs"),
    endpoint("GET", "/api/objectives/{objectiveId}/status-summary", "Read objective status summary.", category="Logs"),
    endpoint("GET", "/api/objectives/{objectiveId}/context-health", "Read objective context-health state.", category="Workflow"),
    endpoint("PATCH", "/api/objectives/{objectiveId}/context-health/{dimensionId}", "Patch a context-health dimension.", category="Workflow", safety="local_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/context-health/{dimensionId}/{action}", "Apply a context-health action.", category="Workflow", safety="local_write", notes="action is one of resolve, reopen, wait, or patch."),
    endpoint("GET", "/api/objectives/{objectiveId}/action-buttons", "List objective action buttons.", category="Action Buttons"),
    endpoint("POST", "/api/objectives/{objectiveId}/action-buttons", "Create objective action buttons.", category="Action Buttons", safety="local_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/action-inject", "Inject an objective action into a session.", category="Action Buttons", safety="terminal_write"),
    endpoint("DELETE", "/api/objectives/{objectiveId}/action-buttons/{buttonId}", "Delete an objective action button.", category="Action Buttons", safety="local_write"),
    endpoint("POST", "/api/objectives/{objectiveId}/open-worktree", "Open an objective worktree in a native editor.", category="Files", safety="native_ui"),
    endpoint("POST", "/api/objectives/{objectiveId}/check-in", "Create a check-in linked to an objective.", category="Workflow", safety="local_write"),

    endpoint("GET", "/api/workspaces", "List workspace sessions tracked by the harness.", category="Workspaces"),
    endpoint("POST", "/api/workspaces", "Create a workspace session record.", category="Workspaces", safety="local_write", request=body_schema(required=["projectId", "rootPath"], optional=["name", "source"], example={"projectId": "project-id", "rootPath": "/Users/ronnierocha/Documents/Development/project", "name": "Review PR"})),
    endpoint("GET", "/api/workspaces/{workspaceId}", "Read a workspace session.", category="Workspaces"),
    endpoint("PATCH", "/api/workspaces/{workspaceId}", "Rename a workspace session.", category="Workspaces", safety="local_write"),
    endpoint("DELETE", "/api/workspaces/{workspaceId}", "Delete a workspace session.", category="Workspaces", safety="terminal_write"),
    endpoint("POST", "/api/workspaces/{workspaceId}/start", "Start a workspace session.", category="Workspaces", safety="terminal_write"),
    endpoint("POST", "/api/workspaces/{workspaceId}/message", "Send input to a workspace session.", category="Workspaces", safety="terminal_write"),
    endpoint("GET", "/api/workspaces/{workspaceId}/messages", "Read workspace messages.", category="Workspaces"),
    endpoint("GET", "/api/workspaces/{workspaceId}/screen", "Read workspace screen output.", category="Workspaces"),
    endpoint("GET", "/api/workspaces/{workspaceId}/active-turn", "Read active workspace turn metadata.", category="Workspaces"),
    endpoint("POST", "/api/workspaces/{workspaceId}/turns/{turnId}/finalize", "Finalize a workspace turn.", category="Workspaces", safety="local_write"),
    endpoint("GET", "/api/workspaces/{workspaceId}/debug", "Read workspace debug logs.", category="Workspaces"),
    endpoint("POST", "/api/workspaces/{workspaceId}/open-root", "Open a workspace root in a native editor.", category="Files", safety="native_ui"),
    endpoint("GET", "/api/workspaces/{workspaceId}/build-log", "Read workspace build log.", category="Logs"),
    endpoint("GET", "/api/workspaces/{workspaceId}/console-logs", "Read workspace console logs.", category="Logs"),
    endpoint("GET", "/api/workspaces/{workspaceId}/status-summary", "Read workspace status summary.", category="Logs"),
    endpoint("GET", "/api/workspaces/{workspaceId}/action-buttons", "List workspace action buttons.", category="Action Buttons"),
    endpoint("POST", "/api/workspaces/{workspaceId}/action-buttons", "Create workspace action buttons.", category="Action Buttons", safety="local_write"),
    endpoint("POST", "/api/workspaces/{workspaceId}/action-inject", "Inject a workspace action into a session.", category="Action Buttons", safety="terminal_write"),
    endpoint("DELETE", "/api/workspaces/{workspaceId}/action-buttons/{buttonId}", "Delete a workspace action button.", category="Action Buttons", safety="local_write"),

    endpoint("GET", "/api/command-center", "Read command-center payload.", category="Workflow"),
    endpoint("GET", "/api/briefing", "Read workflow briefing.", category="Workflow"),
    endpoint("GET", "/api/ideas", "List ideas.", category="Workflow"),
    endpoint("POST", "/api/ideas", "Create an idea.", category="Workflow", safety="local_write"),
    endpoint("GET", "/api/ideas/{ideaId}", "Read an idea.", category="Workflow"),
    endpoint("PATCH", "/api/ideas/{ideaId}", "Update an idea.", category="Workflow", safety="local_write"),
    endpoint("DELETE", "/api/ideas/{ideaId}", "Delete an idea.", category="Workflow", safety="local_write"),
    endpoint("GET", "/api/preflights", "List preflights.", category="Workflow"),
    endpoint("POST", "/api/preflights", "Create a preflight.", category="Workflow", safety="local_write"),
    endpoint("GET", "/api/preflights/{preflightId}", "Read a preflight.", category="Workflow"),
    endpoint("PATCH", "/api/preflights/{preflightId}", "Update a preflight.", category="Workflow", safety="local_write"),
    endpoint("DELETE", "/api/preflights/{preflightId}", "Delete a preflight.", category="Workflow", safety="local_write"),
    endpoint("POST", "/api/preflights/{preflightId}/launch-objective", "Launch a preflight as an objective.", category="Workflow", safety="terminal_write"),
    endpoint("GET", "/api/decisions", "List decisions.", category="Workflow"),
    endpoint("POST", "/api/decisions", "Create a decision.", category="Workflow", safety="local_write"),
    endpoint("GET", "/api/decisions/{decisionId}", "Read a decision.", category="Workflow"),
    endpoint("PATCH", "/api/decisions/{decisionId}", "Patch a decision.", category="Workflow", safety="local_write"),
    endpoint("POST", "/api/decisions/{decisionId}/{action}", "Apply a decision action.", category="Workflow", safety="local_write", notes="action is approve, reject, snooze, or patch."),
    endpoint("GET", "/api/check-ins", "List check-ins.", category="Workflow"),
    endpoint("POST", "/api/check-ins", "Create a check-in.", category="Workflow", safety="local_write"),
    endpoint("GET", "/api/context-health/attention", "List context-health items needing attention.", category="Workflow"),

    endpoint("GET", "/api/jira/assigned", "List assigned Jira tickets through local acli.", category="External Read"),
    endpoint("GET", "/api/jira/issue", "Read a Jira issue through local acli.", category="External Read", parameters=[parameter("key", location="query", description="Jira issue key or URL.")]),
    endpoint("GET", "/api/github/pr-comments", "Read GitHub PR review threads for a workspace path or index.", category="External Read", parameters=[parameter("path", location="query"), parameter("index", location="query"), parameter("includeResolved", location="query", type="boolean", default=False)]),
    endpoint("GET", "/api/skills", "List available local skills.", category="Files"),
    endpoint("GET", "/api/file-search", "Search files/skills.", category="Files"),
    endpoint("POST", "/api/resolve-dropped-files", "Resolve dropped file references.", category="Files", safety="file_read"),
    endpoint("POST", "/api/attachments", "Upload an attachment body.", category="Files", safety="file_write"),
    endpoint("POST", "/api/file-content", "Read a small file from a workspace path.", category="Files", safety="file_read", request=body_schema(required=["path", "file"], example={"path": "/Users/ronnierocha/Documents/Development/project", "file": "README.md"})),
    endpoint("POST", "/api/open-in-native", "Open a file/path in the native app.", category="Files", safety="native_ui"),

    endpoint("GET", "/api/git-status", "Read git status by workspace index.", category="Git", parameters=[parameter("index", location="query", type="integer", required=True)]),
    endpoint("GET", "/api/git-status-path", "Read git status by path.", category="Git", parameters=[parameter("path", location="query", required=True)]),
    endpoint("GET", "/api/screen", "Read live cmux screen by workspace index.", category="Cmux", parameters=[parameter("index", location="query", type="integer", required=True), parameter("lines", location="query", type="integer", default=200)]),
    endpoint("POST", "/api/git-diff", "Read git diff by workspace index.", category="Git", request=body_schema(required=["index", "file"], optional=["section"], example={"index": 0, "file": "Sources/App.swift", "section": "unstaged"})),
    endpoint("POST", "/api/git-diff-path", "Read git diff by path.", category="Git", request=body_schema(required=["path", "file"], optional=["section"], example={"path": "/Users/ronnierocha/Documents/Development/project", "file": "Sources/App.swift", "section": "unstaged"})),
    endpoint("POST", "/api/git-stage", "Stage a file by workspace index.", category="Git", safety="git_write"),
    endpoint("POST", "/api/git-stage-path", "Stage a file by path.", category="Git", safety="git_write"),
    endpoint("POST", "/api/git-unstage", "Unstage a file by workspace index.", category="Git", safety="git_write"),
    endpoint("POST", "/api/git-unstage-path", "Unstage a file by path.", category="Git", safety="git_write"),
    endpoint("POST", "/api/git-open-file", "Open a git file in the native app.", category="Git", safety="native_ui"),
    endpoint("POST", "/api/git-commit-files", "List files changed by a commit.", category="Git"),
    endpoint("POST", "/api/git-commit-diff", "Read file diff for a commit.", category="Git"),

    endpoint("GET", "/api/reviews", "List stored review records.", category="Reviews"),
    endpoint("GET", "/api/reviews/{sessionId}", "Read one stored review.", category="Reviews"),
    endpoint("POST", "/api/reviews/{sessionId}/rerun", "Rerun a stored review.", category="Reviews", safety="local_write"),
    endpoint("POST", "/api/reviews/{sessionId}/dismiss", "Dismiss a stored review.", category="Reviews", safety="local_write"),
    endpoint("POST", "/api/push/register", "Register a push notification device.", category="Notifications", safety="local_write"),
    endpoint("POST", "/api/push/clear", "Clear pending push notifications for a workspace.", category="Notifications", safety="local_write"),
    endpoint("POST", "/api/hooks/pre-tool-use", "Handle a pre-tool-use hook callback.", category="Hooks", safety="local_write"),
    endpoint("POST", "/api/workspace-open-root", "Open workspace root by index or path.", category="Cmux", safety="native_ui"),
    endpoint("POST", "/api/workspace", "Enable/disable a workspace by index.", category="Cmux", safety="local_write"),
    endpoint("POST", "/api/workspace-star", "Star/unstar a workspace by index.", category="Cmux", safety="local_write"),
    endpoint("POST", "/api/rename", "Rename a live workspace by index.", category="Cmux", safety="local_write"),
    endpoint("POST", "/api/send", "Send text or an allowed key to a live workspace.", category="Cmux", safety="terminal_write"),
    endpoint("POST", "/api/new-session", "Create a legacy cmux session/worktree and optionally deliver a prompt.", category="Cmux", safety="terminal_write"),
    endpoint("GET", "/api/workspace-build-log", "Read build log by workspace index or path.", category="Logs"),
    endpoint("GET", "/api/workspace-console-logs", "Read console logs by workspace index or path.", category="Logs"),

    endpoint("GET", "/api/orchestrator-v2/bootstrap", "Read Orchestrator V2 bootstrap payload.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/health", "Read Orchestrator V2 runtime health.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/ai/capabilities", "Read AI/voice/tool capabilities.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/agent/tools", "List Orchestrator V2 agent tools.", category="Orchestrator V2"),
    endpoint("POST", "/api/orchestrator-v2/agent/tools/{toolName}", "Invoke an Orchestrator V2 agent tool.", category="Orchestrator V2", safety="tool_dependent", request=body_schema(optional=["runId", "args"], example={"runId": "run-123", "args": {"repo": "doximity/iOS-Doximity", "number": 11244}})),
    endpoint("GET", "/api/orchestrator-v2/copilotkit/info", "Read CopilotKit capability metadata.", category="Orchestrator V2"),
    endpoint("POST", "/api/orchestrator-v2/copilotkit", "Proxy a CopilotKit request.", category="Orchestrator V2", safety="tool_dependent"),
    endpoint("POST", "/api/orchestrator-v2/ai/chat", "Proxy an AI chat request to the sidecar.", category="Orchestrator V2", safety="external_write"),
    endpoint("POST", "/api/orchestrator-v2/agui/run", "Proxy an AG-UI run request to the sidecar.", category="Orchestrator V2", safety="external_write"),
    endpoint("GET", "/api/orchestrator-v2/tasks", "List Orchestrator V2 tasks.", category="Tasks"),
    endpoint("POST", "/api/orchestrator-v2/tasks", "Create an Orchestrator V2 task and optionally cmux session.", category="Tasks", safety="terminal_write"),
    endpoint("GET", "/api/orchestrator-v2/tasks/{taskId}", "Read an Orchestrator V2 task.", category="Tasks"),
    endpoint("PATCH", "/api/orchestrator-v2/tasks/{taskId}", "Update an Orchestrator V2 task.", category="Tasks", safety="local_write"),
    endpoint("DELETE", "/api/orchestrator-v2/tasks/{taskId}", "Delete an Orchestrator V2 task.", category="Tasks", safety="local_write"),
    endpoint("GET", "/api/orchestrator-v2/tasks/{taskId}/goal", "Read task goal markdown.", category="Tasks"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/goal", "Update task goal markdown.", category="Tasks", safety="file_write"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/jira-links", "Attach Jira metadata to a task.", category="Tasks", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/jira-links/{linkId}/resync", "Refresh task Jira metadata.", category="Tasks", safety="external_read"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/pr-links", "Attach PR metadata to a task.", category="Tasks", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/cmux-sessions", "Attach a cmux session to a task.", category="Tasks", safety="local_write"),
    endpoint("DELETE", "/api/orchestrator-v2/tasks/{taskId}/cmux-sessions/{linkId}", "Detach a cmux session from a task.", category="Tasks", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/tasks/{taskId}/summarize-sessions", "Summarize task cmux session output.", category="Tasks", safety="local_write"),
    endpoint("GET", "/api/orchestrator-v2/left-rail", "Read left-rail Jira/PR data.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/left-rail/jira", "Read left-rail assigned Jira tickets.", category="External Read"),
    endpoint("GET", "/api/orchestrator-v2/left-rail/open-prs", "Read left-rail open PRs authored by me.", category="External Read"),
    endpoint("GET", "/api/orchestrator-v2/left-rail/draft-prs", "Read left-rail draft PRs authored by me.", category="External Read"),
    endpoint("GET", "/api/orchestrator-v2/left-rail/review-requests", "Read left-rail PRs requesting my review.", category="External Read"),

    endpoint("GET", "/api/orchestrator-v2/pr-reviews/review-requests", "List PRs requesting my review for a repository.", category="PR Reviews", parameters=[parameter("repo", location="query", default="doximity/iOS-Doximity", description="GitHub repository in owner/name form."), parameter("limit", location="query", type="integer", default=20)], related_tools=["list_pr_review_requests"], examples=[{"description": "List iOS review requests.", "request": {"method": "GET", "path": "/api/orchestrator-v2/pr-reviews/review-requests?repo=doximity/iOS-Doximity&limit=20"}}]),
    endpoint("POST", "/api/orchestrator-v2/pr-reviews/start", "Start a remote PR code review in a new cmux workspace and create/link an Orchestrator V2 task.", category="PR Reviews", safety="terminal_write", parameters=[
        parameter("number", type="integer", required=True, description="Pull request number to review."),
        parameter("repo", required=False, default="doximity/iOS-Doximity", description="GitHub repository in owner/name form."),
        parameter("projectDir", required=False, default="~/Documents/Development/Doximity-Claude", description="Local project directory where the agent runs."),
        parameter("reviewCli", required=False, default="codex", enum=["codex", "claude"], description="Agent CLI to launch inside cmux."),
        parameter("pullRequest", type="object", description="Optional already-discovered PR metadata to avoid a GitHub lookup."),
        parameter("taskId", description="Optional existing Orchestrator V2 task to attach the launched review to."),
    ], request=body_schema(required=["number"], optional=["repo", "projectDir", "reviewCli", "pullRequest", "taskId", "title", "priority", "tags"], example={"repo": "doximity/iOS-Doximity", "number": 11244, "reviewCli": "codex"}), related_tools=["start_pr_review"], examples=[{"description": "Start PR review with defaults.", "request": {"method": "POST", "path": "/api/orchestrator-v2/pr-reviews/start", "json": {"repo": "doximity/iOS-Doximity", "number": 11244}}}]),

    endpoint("GET", "/api/orchestrator-v2/cmux/sessions", "List cmux sessions through the cmux CLI.", category="Cmux"),
    endpoint("POST", "/api/orchestrator-v2/cmux/sessions", "Create a cmux session.", category="Cmux", safety="terminal_write"),
    endpoint("GET", "/api/orchestrator-v2/cmux/sessions/{workspaceId}/screen", "Read a cmux session screen.", category="Cmux"),
    endpoint("POST", "/api/orchestrator-v2/cmux/sessions/{workspaceId}/input", "Send text or key input to a cmux session.", category="Cmux", safety="terminal_write"),
    endpoint("GET", "/api/orchestrator-v2/orphans", "List active unlinked cmux sessions.", category="Cmux"),
    endpoint("GET", "/api/orchestrator-v2/git/status", "Read git status for a path.", category="Git"),
    endpoint("POST", "/api/orchestrator-v2/git/diff", "Read git diff for a path/file.", category="Git"),
    endpoint("POST", "/api/orchestrator-v2/git/commit-files", "List files changed by a commit.", category="Git"),
    endpoint("POST", "/api/orchestrator-v2/git/commit-diff", "Read file diff for a commit.", category="Git"),
    endpoint("POST", "/api/orchestrator-v2/git/stage", "Stage a file.", category="Git", safety="git_write"),
    endpoint("POST", "/api/orchestrator-v2/git/unstage", "Unstage a file.", category="Git", safety="git_write"),
    endpoint("POST", "/api/orchestrator-v2/open-in-native", "Open a file/path in the native app.", category="Files", safety="native_ui"),
    endpoint("GET", "/api/orchestrator-v2/approvals", "List approval requests.", category="Approvals"),
    endpoint("POST", "/api/orchestrator-v2/approvals", "Create an approval request.", category="Approvals", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/approvals/{requestId}/decision", "Decide an approval request.", category="Approvals", safety="external_write"),
    endpoint("PATCH", "/api/orchestrator-v2/approvals/{requestId}", "Patch/decide an approval request.", category="Approvals", safety="external_write"),
    endpoint("GET", "/api/orchestrator-v2/activity", "List Orchestrator V2 activity events.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/audit", "List Orchestrator V2 audit events.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/agent/tool-runs", "List agent tool runs.", category="Orchestrator V2"),
    endpoint("POST", "/api/orchestrator-v2/agent/context", "Read context for an agent.", category="Orchestrator V2"),
    endpoint("POST", "/api/orchestrator-v2/agent/transcript", "Append an agent transcript message.", category="Orchestrator V2", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/agent/runs", "Create an agent run record.", category="Orchestrator V2", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/agent/runs/{runId}/finish", "Finish an agent run record.", category="Orchestrator V2", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/agent/agui-events", "Record AG-UI events.", category="Orchestrator V2", safety="local_write"),
    endpoint("GET", "/api/orchestrator-v2/agui/runs/{runId}/events", "Read AG-UI events for a run.", category="Orchestrator V2"),
    endpoint("GET", "/api/orchestrator-v2/chat/messages", "Read global chat messages.", category="Orchestrator V2"),
    endpoint("POST", "/api/orchestrator-v2/chat", "Run a local Orchestrator V2 chat turn.", category="Orchestrator V2", safety="local_write"),
    endpoint("POST", "/api/orchestrator-v2/realtime/session", "Create realtime voice session credentials.", category="Voice", safety="external_write"),
    endpoint("POST", "/api/orchestrator-v2/realtime/tool", "Run a realtime tool call.", category="Voice", safety="tool_dependent"),
    endpoint("POST", "/api/orchestrator-v2/voice/local/transcribe", "Transcribe local audio.", category="Voice", safety="file_read"),
    endpoint("POST", "/api/orchestrator-v2/voice/local/speak", "Generate local speech audio.", category="Voice", safety="file_write"),
    endpoint("POST", "/api/orchestrator-v2/folder-picker", "Open native folder picker.", category="Files", safety="native_ui"),
    endpoint("POST", "/api/orchestrator-v2/watcher/run", "Run Orchestrator V2 watcher once.", category="Orchestrator V2", safety="external_read"),
]
