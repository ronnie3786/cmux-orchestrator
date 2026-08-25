from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.parse
from pathlib import Path
from typing import Any

from .. import cmux_cli
from .. import orchestrator_v2_enrich
from .. import orchestrator_v2_runtime
from .. import orchestrator_v2_storage as v2
from .. import orchestrator_v2_voice
from .. import pr_review_orchestrator as pr_reviews
from ..orchestrator_v2_security import redact_text
from . import jira as jira_routes


class OrchestratorV2RouteError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def handle_get(handler, parsed, *, engine) -> bool:
    path = parsed.path
    repo = v2.get_repository()
    try:
        if path == "/api/orchestrator-v2/events/stream":
            return stream_state_events(handler, parsed, repo=repo)
        if path == "/api/orchestrator-v2/events/token":
            handler._json_response({"ok": True, "token": repo.state_token()})
            return True
        if path == "/api/orchestrator-v2/bootstrap":
            payload = bootstrap_payload(repo=repo)
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/health":
            payload = orchestrator_v2_runtime.health_payload(repo=repo)
            handler._json_response(payload, 200 if payload.get("ok") else 503)
            return True
        if path == "/api/orchestrator-v2/ai/capabilities":
            handler._json_response({"ok": True, **agent_capabilities_payload()})
            return True
        if path == "/api/orchestrator-v2/agent/tools":
            handler._json_response({"ok": True, "tools": agent_tool_specs()})
            return True
        if path == "/api/orchestrator-v2/copilotkit/info":
            handler._json_response(copilotkit_info_payload())
            return True
        if path == "/api/orchestrator-v2/tasks":
            params = handler.parse_qs(parsed.query)
            include_history = _parse_bool(params.get("includeHistory", ["false"])[0])
            query = str(params.get("q", [""])[0] or "")
            handler._json_response({"ok": True, "tasks": repo.list_tasks(include_history=include_history, query=query)})
            return True
        if path.startswith("/api/orchestrator-v2/tasks/"):
            task_id, suffix = _task_suffix(path)
            if suffix == "":
                task = repo.get_task(task_id)
                if task is None:
                    raise OrchestratorV2RouteError("task not found", 404)
                handler._json_response({"ok": True, "task": task})
                return True
            if suffix == "/goal":
                handler._json_response({"ok": True, "goal": repo.read_goal(task_id)})
                return True
        if path == "/api/orchestrator-v2/left-rail":
            handler._json_response({"ok": True, **left_rail_payload()})
            return True
        if path == "/api/orchestrator-v2/left-rail/jira":
            handler._json_response({"ok": True, "tickets": list_assigned_jira()})
            return True
        if path == "/api/orchestrator-v2/left-rail/open-prs":
            handler._json_response({"ok": True, "pullRequests": list_my_open_prs()})
            return True
        if path == "/api/orchestrator-v2/left-rail/draft-prs":
            handler._json_response({"ok": True, "pullRequests": list_my_draft_prs()})
            return True
        if path == "/api/orchestrator-v2/left-rail/review-requests":
            handler._json_response({"ok": True, "pullRequests": list_prs_waiting_for_review()})
            return True
        if path == "/api/orchestrator-v2/pr-reviews/review-requests":
            params = handler.parse_qs(parsed.query)
            payload = list_pr_review_requests({
                "repo": params.get("repo", [pr_reviews.DEFAULT_REPO])[0],
                "limit": params.get("limit", [20])[0],
            })
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/cmux/sessions":
            sessions = get_cmux_cli().list_sessions()
            repo.record_cmux_snapshots(sessions)
            handler._json_response({"ok": True, "sessions": sessions})
            return True
        if path.startswith("/api/orchestrator-v2/cmux/sessions/") and path.endswith("/screen"):
            workspace_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/cmux/sessions/"):-len("/screen")]).strip("/")
            params = handler.parse_qs(parsed.query)
            surface_id = str(params.get("surfaceId", [""])[0] or "")
            lines = int(str(params.get("lines", ["200"])[0] or "200"))
            screen = get_cmux_cli().read_session(workspace_id, surface_id, lines=lines)
            handler._json_response({"ok": True, "workspaceId": workspace_id, "surfaceId": surface_id, "screen": screen})
            return True
        if path == "/api/orchestrator-v2/orphans":
            try:
                sessions = get_cmux_cli().list_sessions()
                orphans = repo.record_cmux_snapshots(sessions)
            except cmux_cli.CmuxCliError:
                orphans = repo.list_orphans()
            handler._json_response({"ok": True, "orphans": orphans})
            return True
        if path == "/api/orchestrator-v2/git/status":
            params = handler.parse_qs(parsed.query)
            target = _resolve_path_param(params)
            result = fake_git_status() if _fake_providers_enabled() else engine.get_git_status_for_path(target)
            result["ok"] = True
            handler._json_response(result)
            return True
        if path == "/api/orchestrator-v2/approvals":
            params = handler.parse_qs(parsed.query)
            status = str(params.get("status", [""])[0] or "").strip() or None
            handler._json_response({"ok": True, "approvals": repo.list_approval_requests(status=status)})
            return True
        if path == "/api/orchestrator-v2/activity":
            params = handler.parse_qs(parsed.query)
            limit = int(str(params.get("limit", ["100"])[0] or "100"))
            handler._json_response({"ok": True, "activity": repo.list_activity_events(limit=limit)})
            return True
        if path == "/api/orchestrator-v2/audit":
            params = handler.parse_qs(parsed.query)
            limit = int(str(params.get("limit", ["100"])[0] or "100"))
            handler._json_response({"ok": True, "audit": repo.list_audit_events(limit=limit)})
            return True
        if path == "/api/orchestrator-v2/agent/tool-runs":
            params = handler.parse_qs(parsed.query)
            limit = int(str(params.get("limit", ["200"])[0] or "200"))
            run_id = str(params.get("runId", [""])[0] or "")
            handler._json_response({"ok": True, "toolRuns": repo.list_tool_runs(run_id=run_id, limit=limit)})
            return True
        if path == "/api/orchestrator-v2/chat/messages":
            handler._json_response({"ok": True, "messages": repo.list_chat_messages()})
            return True
        if path.startswith("/api/orchestrator-v2/agui/runs/") and path.endswith("/events"):
            run_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/agui/runs/"):-len("/events")]).strip("/")
            handler._json_response({"ok": True, "runId": run_id, "events": repo.list_agui_events(run_id)})
            return True
    except (v2.V2StorageError, OrchestratorV2RouteError, cmux_cli.CmuxCliError, pr_reviews.PRReviewOrchestratorError, RuntimeError, ValueError) as exc:
        handler._json_response({"ok": False, "error": str(exc)}, getattr(exc, "status", 500))
        return True
    return False


def handle_post(handler, parsed, data: dict[str, Any], *, engine) -> bool:
    path = parsed.path
    repo = v2.get_repository()
    try:
        if path in {"/api/orchestrator-v2/ai/chat", "/api/orchestrator-v2/agui/run"}:
            sidecar_path = path[len("/api/orchestrator-v2"):]
            return orchestrator_v2_runtime.proxy_stream(handler, f"/api/orchestrator-v2{sidecar_path}", data)
        if path == "/api/orchestrator-v2/agent/context":
            handler._json_response({"ok": True, **agent_context_payload(repo=repo)})
            return True
        if path == "/api/orchestrator-v2/agent/transcript":
            message = repo.append_chat_message(
                str(data.get("role") or "user"),
                str(data.get("content") or ""),
                data.get("metadata") if isinstance(data.get("metadata"), dict) else {},
            )
            handler._json_response({"ok": True, "message": message}, 201)
            return True
        if path == "/api/orchestrator-v2/agent/runs":
            run = repo.create_agent_run(
                str(data.get("runId") or data.get("id") or v2.safe_id("run")),
                mode=str(data.get("mode") or "text"),
                input_payload=data.get("input") if isinstance(data.get("input"), dict) else data,
            )
            handler._json_response({"ok": True, "run": run}, 201)
            return True
        if path.startswith("/api/orchestrator-v2/agent/runs/") and path.endswith("/finish"):
            run_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/agent/runs/"):-len("/finish")]).strip("/")
            run = repo.finish_agent_run(
                run_id,
                status=str(data.get("status") or "completed"),
                output_payload=data.get("output") if isinstance(data.get("output"), dict) else data,
            )
            handler._json_response({"ok": True, "run": run})
            return True
        if path == "/api/orchestrator-v2/agent/agui-events":
            events = data.get("events") if isinstance(data.get("events"), list) else [data.get("event") or data]
            stored = repo.record_agui_events(str(data.get("runId") or ""), events)
            handler._json_response({"ok": True, "events": stored}, 201)
            return True
        if path == "/api/orchestrator-v2/realtime/session":
            tools = realtime_tool_specs()
            payload = orchestrator_v2_voice.realtime_client_secret_payload({**data, "tools": tools})
            handler._json_response(payload)
            return True
        if path == "/api/orchestrator-v2/realtime/tool":
            tool_name = str(data.get("toolName") or data.get("name") or "")
            payload = run_agent_tool(repo, tool_name, data, engine=engine)
            handler._json_response({"ok": True, "tool": tool_name, "result": payload})
            return True
        if path == "/api/orchestrator-v2/voice/local/transcribe":
            payload = orchestrator_v2_voice.transcribe_local_payload(data)
            append_chat = _parse_bool(data.get("appendChat", True)) and not _parse_bool(data.get("partial", False))
            if append_chat and payload.get("text"):
                repo.append_chat_message("user", str(payload["text"]), {"mode": "local_voice", "source": "stt"})
            handler._json_response(payload)
            return True
        if path == "/api/orchestrator-v2/voice/local/speak":
            payload = orchestrator_v2_voice.speak_local_payload(data)
            handler._json_response(payload)
            return True
        if path == "/api/orchestrator-v2/voice/enrich":
            try:
                payload = orchestrator_v2_enrich.enrich_payload(data)
            except RuntimeError as exc:
                raise OrchestratorV2RouteError(str(exc), 502) from exc
            handler._json_response(payload)
            return True
        if path == "/api/orchestrator-v2/folder-picker":
            handler._json_response({"ok": True, "path": choose_project_folder(data)})
            return True
        if path == "/api/orchestrator-v2/tasks":
            payload = dict(data or {})
            session = payload.get("existingCmuxSession") if isinstance(payload.get("existingCmuxSession"), dict) else None
            workspace_dir = str(payload.get("workspaceDir") or "").strip()
            if not workspace_dir and session is not None:
                workspace_dir = session_cwd(session)
                payload["workspaceDir"] = workspace_dir
            if not workspace_dir:
                raise OrchestratorV2RouteError("workspaceDir required", 400)
            if not os.path.isdir(os.path.expanduser(workspace_dir)):
                raise OrchestratorV2RouteError(f"workspaceDir not found: {workspace_dir}", 400)
            if session is not None and not str(payload.get("title") or "").strip():
                payload["title"] = str(session.get("title") or session.get("workspaceId") or "New Task")
            launch_type = v2.normalize_launch_type(payload.get("sessionLaunchType") or payload.get("launchType"))
            if session is None:
                session = get_cmux_cli().create_session(
                    title=str(payload.get("title") or "New Task"),
                    cwd=workspace_dir,
                    launch_type=launch_type,
                )
            task = repo.create_task(payload, cmux_session=session, actor="local")
            handler._json_response({"ok": True, "task": task, "cmuxSession": session}, 201)
            return True
        if path.startswith("/api/orchestrator-v2/tasks/"):
            task_id, suffix = _task_suffix(path)
            if suffix.startswith("/jira-links/") and suffix.endswith("/resync"):
                link_id = urllib.parse.unquote(suffix[len("/jira-links/"):-len("/resync")]).strip("/")
                task = repo.get_task(task_id)
                if task is None:
                    raise OrchestratorV2RouteError("task not found", 404)
                current_link = next(
                    (
                        link for link in task.get("jiraLinks", [])
                        if link.get("id") == link_id or str(link.get("key") or "").upper() == link_id.upper()
                    ),
                    None,
                )
                if current_link is None:
                    raise OrchestratorV2RouteError("Jira link not found", 404)
                ticket = find_jira_ticket(str(current_link.get("key") or ""))
                if ticket is None:
                    raise OrchestratorV2RouteError("Jira ticket not found", 404)
                link = repo.resync_jira_link(task_id, link_id, ticket)
                handler._json_response({"ok": True, "jiraLink": link})
                return True
            if suffix == "/jira-links":
                ticket = data.get("ticket") if isinstance(data.get("ticket"), dict) else data
                if not ticket.get("key") and ticket.get("url"):
                    fetched = find_jira_ticket(str(ticket.get("url") or ""))
                    ticket = fetched or ticket
                link = repo.attach_jira(task_id, ticket)
                handler._json_response({"ok": True, "jiraLink": link}, 201)
                return True
            if suffix == "/pr-links":
                pr = data.get("pullRequest") if isinstance(data.get("pullRequest"), dict) else data
                link = repo.attach_pr(task_id, pr)
                handler._json_response({"ok": True, "pullRequestLink": link}, 201)
                return True
            if suffix == "/cmux-sessions":
                session = data.get("session") if isinstance(data.get("session"), dict) else data
                link = repo.attach_cmux_session(
                    task_id,
                    session,
                    launch_type=str(data.get("launchType") or session.get("launchType") or "Empty shell"),
                )
                handler._json_response({"ok": True, "cmuxSessionLink": link}, 201)
                return True
            if suffix == "/goal":
                goal = repo.update_goal(task_id, str(data.get("content") or ""))
                handler._json_response({"ok": True, "goal": goal})
                return True
            if suffix == "/summarize-sessions":
                texts = data.get("sessionTexts")
                if not isinstance(texts, list):
                    task = repo.get_task(task_id)
                    if task is None:
                        raise OrchestratorV2RouteError("task not found", 404)
                    texts = []
                    for link in task.get("cmuxSessionLinks", []):
                        try:
                            texts.append(get_cmux_cli().read_session(link["workspaceId"], link.get("surfaceId", ""), lines=200))
                        except cmux_cli.CmuxCliError:
                            continue
                summary = repo.summarize_task_sessions(task_id, [str(item) for item in texts])
                handler._json_response({"ok": True, "summary": summary})
                return True
        if path == "/api/orchestrator-v2/cmux/sessions":
            launch_type = v2.normalize_launch_type(data.get("launchType"))
            session = get_cmux_cli().create_session(
                title=str(data.get("title") or "New Session"),
                cwd=str(data.get("workspaceDir") or data.get("cwd") or ""),
                launch_type=launch_type,
            )
            repo.record_cmux_snapshots([session])
            handler._json_response({"ok": True, "session": session}, 201)
            return True
        if path == "/api/orchestrator-v2/pr-reviews/start":
            payload = start_pr_review(repo, data, actor="local")
            handler._json_response({"ok": True, **payload}, 201)
            return True
        if path.startswith("/api/orchestrator-v2/cmux/sessions/") and path.endswith("/kill"):
            workspace_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/cmux/sessions/"):-len("/kill")]).strip("/")
            payload = kill_cmux_session_now(repo, workspace_id, data, actor="local")
            handler._json_response({"ok": True, **payload})
            return True
        if path.startswith("/api/orchestrator-v2/cmux/sessions/") and path.endswith("/restart"):
            workspace_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/cmux/sessions/"):-len("/restart")]).strip("/")
            payload = restart_cmux_session_now(repo, workspace_id, data, actor="local")
            handler._json_response({"ok": True, **payload})
            return True
        if path.startswith("/api/orchestrator-v2/cmux/sessions/") and path.endswith("/input"):
            workspace_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/cmux/sessions/"):-len("/input")]).strip("/")
            surface_id = str(data.get("surfaceId") or "")
            text = data.get("text")
            key = str(data.get("key") or "").strip().lower()
            if not workspace_id:
                raise OrchestratorV2RouteError("workspaceId required", 400)
            if text is None and not key:
                raise OrchestratorV2RouteError("text or key required", 400)
            if text is not None:
                result = get_cmux_cli().send_text(workspace_id, str(text), surface_id=surface_id)
            else:
                result = get_cmux_cli().send_key(workspace_id, key, surface_id=surface_id)
            handler._json_response({"ok": True, "result": result})
            return True
        if path == "/api/orchestrator-v2/git/diff":
            target = _resolve_body_path(data)
            file = str(data.get("file") or "").strip()
            if not file:
                raise OrchestratorV2RouteError("file required", 400)
            section = str(data.get("section") or "unstaged")
            diff = read_git_diff(engine, target, file, section)
            handler._json_response({"ok": True, "path": target, "file": file, "section": section, "diff": diff})
            return True
        if path == "/api/orchestrator-v2/git/commit-files":
            target = _resolve_body_path(data)
            commit_hash = _validated_commit_hash(data.get("hash"))
            files = read_git_commit_files(engine, target, commit_hash)
            handler._json_response({"ok": True, "path": target, "hash": commit_hash, "files": files})
            return True
        if path == "/api/orchestrator-v2/git/commit-diff":
            target = _resolve_body_path(data)
            commit_hash = _validated_commit_hash(data.get("hash"))
            file = str(data.get("file") or "").strip()
            if not file:
                raise OrchestratorV2RouteError("file required", 400)
            diff = read_git_commit_diff(engine, target, commit_hash, file)
            handler._json_response({"ok": True, "path": target, "hash": commit_hash, "file": file, "diff": diff})
            return True
        if path == "/api/orchestrator-v2/git/stage":
            payload = update_git_index(engine, data, stage=True)
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/git/unstage":
            payload = update_git_index(engine, data, stage=False)
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/open-in-native":
            payload = open_native_file(data)
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/approvals":
            approval = repo.create_approval_request(data, actor="agent")
            handler._json_response({"ok": True, "approval": approval}, 201)
            return True
        if path.startswith("/api/orchestrator-v2/approvals/") and path.endswith("/decision"):
            request_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/approvals/"):-len("/decision")]).strip("/")
            before = repo.get_approval_request(request_id)
            approval = repo.decide_approval_request(request_id, str(data.get("status") or ""))
            execution = execute_approved_payload(repo, before, approval) if approval.get("status") == "approved" else None
            if execution is not None:
                approval["execution"] = execution
            handler._json_response({"ok": True, "approval": approval})
            return True
        if path == "/api/orchestrator-v2/watcher/run":
            payload = run_watcher_once(repo=repo)
            handler._json_response({"ok": True, **payload})
            return True
        if path == "/api/orchestrator-v2/chat":
            payload = handle_chat_turn(repo, data)
            handler._json_response({"ok": True, **payload})
            return True
        if path.startswith("/api/orchestrator-v2/copilotkit"):
            if data.get("method") == "info":
                handler._json_response(copilotkit_info_payload())
                return True
            return orchestrator_v2_runtime.proxy_stream(handler, "/api/orchestrator-v2/copilotkit", data)
        if path.startswith("/api/orchestrator-v2/agent/tools/"):
            tool_name = urllib.parse.unquote(path[len("/api/orchestrator-v2/agent/tools/"):]).strip("/")
            payload = run_agent_tool(repo, tool_name, data, engine=engine)
            handler._json_response({"ok": True, "tool": tool_name, "result": payload})
            return True
    except (v2.V2StorageError, OrchestratorV2RouteError, cmux_cli.CmuxCliError, pr_reviews.PRReviewOrchestratorError, RuntimeError, ValueError) as exc:
        handler._json_response({"ok": False, "error": str(exc)}, getattr(exc, "status", 500))
        return True
    return False


def handle_patch(handler, parsed, data: dict[str, Any], *, engine) -> bool:
    path = parsed.path
    repo = v2.get_repository()
    try:
        if path.startswith("/api/orchestrator-v2/tasks/"):
            task_id, suffix = _task_suffix(path)
            if suffix == "":
                task = repo.update_task(task_id, data)
                handler._json_response({"ok": True, "task": task})
                return True
        if path.startswith("/api/orchestrator-v2/approvals/"):
            request_id = urllib.parse.unquote(path[len("/api/orchestrator-v2/approvals/"):]).strip("/")
            before = repo.get_approval_request(request_id)
            approval = repo.decide_approval_request(request_id, str(data.get("status") or ""))
            execution = execute_approved_payload(repo, before, approval) if approval.get("status") == "approved" else None
            if execution is not None:
                approval["execution"] = execution
            handler._json_response({"ok": True, "approval": approval})
            return True
    except (v2.V2StorageError, OrchestratorV2RouteError) as exc:
        handler._json_response({"ok": False, "error": str(exc)}, getattr(exc, "status", 500))
        return True
    return False


def handle_delete(handler, parsed, *, engine) -> bool:
    path = parsed.path
    repo = v2.get_repository()
    try:
        if path.startswith("/api/orchestrator-v2/tasks/") and "/cmux-sessions/" in path:
            prefix = path[len("/api/orchestrator-v2/tasks/"):]
            task_id, rest = prefix.split("/cmux-sessions/", 1)
            link_id = urllib.parse.unquote(rest).strip("/")
            repo.detach_cmux_session(urllib.parse.unquote(task_id), link_id)
            handler._json_response({"ok": True})
            return True
        if path.startswith("/api/orchestrator-v2/tasks/"):
            task_id, suffix = _task_suffix(path)
            if suffix == "":
                repo.delete_task(task_id)
                handler._json_response({"ok": True})
                return True
    except v2.V2StorageError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, exc.status)
        return True
    return False


def stream_state_events(handler, parsed, *, repo: v2.V2Repository) -> bool:
    """Server-sent events stream that fires whenever durable V2 state changes.

    The client refetches full data on each `update` event, so the stream only
    needs to be a cheap change signal, not a data channel.
    """
    params = handler.parse_qs(parsed.query)
    poll_seconds = min(max(float(str(params.get("interval", ["2"])[0] or "2")), 0.5), 15.0)
    max_seconds = min(max(float(str(params.get("maxSeconds", ["3600"])[0] or "3600")), 5.0), 6 * 3600.0)
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream; charset=utf-8")
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("X-Accel-Buffering", "no")
        handler.end_headers()
    except (BrokenPipeError, ConnectionResetError):
        return True

    def write_event(event: str, payload: dict[str, Any]) -> bool:
        try:
            handler.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode("utf-8"))
            handler.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    token = repo.state_token()
    if not write_event("connected", {"ok": True}):
        return True
    started = time.monotonic()
    last_heartbeat = started
    while time.monotonic() - started < max_seconds:
        time.sleep(poll_seconds)
        try:
            current = repo.state_token()
        except Exception:
            continue
        now = time.monotonic()
        if current != token:
            token = current
            if not write_event("update", {"changedAt": v2.now_iso()}):
                return True
            last_heartbeat = now
        elif now - last_heartbeat >= 15.0:
            if not write_event("heartbeat", {"ok": True}):
                return True
            last_heartbeat = now
    return True


def bootstrap_payload(*, repo: v2.V2Repository) -> dict[str, Any]:
    try:
        left_rail = left_rail_payload()
    except OrchestratorV2RouteError as exc:
        left_rail = {"error": str(exc), "assignedJira": [], "openPrs": [], "draftPrs": [], "reviewRequests": []}
    return {
        "tasks": repo.list_tasks(),
        "history": repo.list_tasks(include_history=True),
        "approvals": repo.list_approval_requests(status="pending"),
        "activity": repo.list_activity_events(limit=100),
        "leftRail": left_rail,
        "chatMessages": repo.list_chat_messages(limit=100),
        "taskStatuses": sorted(v2.TASK_STATUSES),
        "taskPriorities": sorted(v2.TASK_PRIORITIES),
        "sessionLaunchTypes": ["Empty shell", "Codex", "Claude Code", "OpenCode"],
        "agentCapabilities": agent_capabilities_payload(),
    }


def copilotkit_info_payload() -> dict[str, Any]:
    return {
        "version": "1.0.0",
        "agents": {
            "default": {
                "description": "Orchestrator V2 top-level control plane",
                "capabilities": {
                    "readableContext": True,
                    "frontendTools": True,
                    "humanInTheLoop": True,
                },
            }
        },
        "audioFileTranscriptionEnabled": True,
        "aguiEnabled": True,
        "controlledGenerativeUIEnabled": True,
        "a2uiEnabled": False,
        "openGenerativeUIEnabled": False,
    }


def agent_capabilities_payload() -> dict[str, Any]:
    health = orchestrator_v2_runtime.health_payload(repo=v2.get_repository())
    checks = health["checks"]
    unsupported = sorted(name for name, spec in agent_tool_specs().items() if spec.get("status") == "not_implemented")
    stt_backend = str(os.environ.get("ORCHESTRATOR_V2_STT_BACKEND") or "parakeet").strip().lower()
    tts_provider = str(os.environ.get("ORCHESTRATOR_V2_TTS_BACKEND") or "kokoro").strip().lower()
    if stt_backend == "parakeet":
        stt_available = bool(checks["parakeet"]["available"] or checks["fasterWhisper"]["available"])
    else:
        stt_available = bool(checks["fasterWhisper"]["available"])
    tts_available = bool((checks.get(tts_provider) or checks["kokoro"]).get("available"))
    return {
        "provider": "fireworks",
        "model": os.environ.get("ORCHESTRATOR_V2_AGENT_MODEL") or "accounts/fireworks/models/minimax-m2p7",
        "streaming": True,
        "agui": True,
        "voiceModes": {
            "text": {"available": True},
            "realtime": checks["openaiRealtime"],
            "local": {
                "available": bool(stt_available and tts_available),
                "stt": {"backend": stt_backend, "available": stt_available},
                "tts": {"provider": tts_provider, "available": tts_available},
                "enrich": bool(checks["fireworks"]["available"]),
                "elevenlabs": checks["elevenlabs"],
            },
            "visual": bool(checks["parakeet"]["available"] and checks["kokoro"]["available"]),
        },
        "tools": agent_tool_specs(),
        "unsupported": unsupported,
        "health": health,
    }


def agent_context_payload(*, repo: v2.V2Repository) -> dict[str, Any]:
    return {
        "tasks": repo.list_tasks(),
        "history": repo.list_tasks(include_history=True),
        "approvals": repo.list_approval_requests(status="pending"),
        "activity": repo.list_activity_events(limit=100),
        "audit": repo.list_audit_events(limit=50),
        "chatMessages": repo.list_chat_messages(limit=80),
        "toolRuns": repo.list_tool_runs(limit=100),
        "leftRail": left_rail_payload(),
    }


def agent_tool_specs() -> dict[str, dict[str, Any]]:
    available = "available"
    approval = "approval_required"
    not_impl = "not_implemented"
    specs: dict[str, dict[str, Any]] = {
        "list_tasks": {"status": available, "kind": "read"},
        "get_task": {"status": available, "kind": "read"},
        "search_tasks": {"status": available, "kind": "read"},
        "list_cmux_sessions": {"status": available, "kind": "read"},
        "read_cmux_session": {"status": available, "kind": "read"},
        "search_cmux_sessions": {"status": available, "kind": "read"},
        "inspect_cmux_session": {"status": available, "kind": "read"},
        "summarize_task_sessions": {"status": available, "kind": "local_update"},
        "read_goal_markdown": {"status": available, "kind": "read"},
        "find_jira_ticket": {"status": available, "kind": "read"},
        "list_assigned_jira": {"status": available, "kind": "read"},
        "list_my_open_prs": {"status": available, "kind": "read"},
        "list_my_draft_prs": {"status": available, "kind": "read"},
        "list_prs_waiting_for_review": {"status": available, "kind": "read"},
        "list_pr_review_requests": {"status": available, "kind": "read"},
        "start_pr_review": {"status": available, "kind": "local_update"},
        "get_git_status": {"status": available, "kind": "read"},
        "get_git_diff": {"status": available, "kind": "read"},
        "create_task": {"status": available, "kind": "local_update"},
        "update_task_status": {"status": available, "kind": "local_update"},
        "update_task_priority": {"status": available, "kind": "local_update"},
        "update_task_tags": {"status": available, "kind": "local_update"},
        "attach_jira_to_task": {"status": available, "kind": "local_update"},
        "attach_pr_to_task": {"status": available, "kind": "local_update"},
        "attach_cmux_session_to_task": {"status": available, "kind": "local_update"},
        "detach_cmux_session_from_task": {"status": available, "kind": "local_update"},
        "create_cmux_session": {"status": available, "kind": "local_update"},
        "launch_coding_agent": {"status": available, "kind": "local_update"},
        "send_cmux_prompt": {"status": available, "kind": "local_update"},
        "send_cmux_key": {"status": available, "kind": "local_update"},
        "update_goal_markdown": {"status": available, "kind": "local_update"},
        "create_approval_request": {"status": available, "kind": "local_update"},
        "post_jira_comment": {"status": approval, "kind": "external_write", "requiresApproval": True},
        "transition_jira_status": {"status": available, "kind": "external_write", "requiresApproval": False},
        "post_pr_reply": {"status": not_impl, "kind": "external_write"},
        "submit_pr_review": {"status": not_impl, "kind": "external_write"},
        "run_destructive_git_operation": {"status": not_impl, "kind": "external_write"},
        "kill_cmux_session": {"status": approval, "kind": "cmux_lifecycle", "requiresApproval": True},
        "restart_cmux_session": {"status": approval, "kind": "cmux_lifecycle", "requiresApproval": True},
    }
    return specs


def realtime_tool_specs() -> list[dict[str, Any]]:
    tools = []
    for name, spec in agent_tool_specs().items():
        if spec["status"] == "not_implemented":
            continue
        tools.append({
            "type": "function",
            "name": name,
            "description": f"Run Orchestrator V2 backend tool {name} through the audited local Python safety layer.",
            "parameters": {"type": "object", "properties": {}, "additionalProperties": True},
        })
    return tools


def left_rail_payload() -> dict[str, Any]:
    return {
        "assignedJira": safe_provider_list(list_assigned_jira),
        "openPrs": safe_provider_list(list_my_open_prs),
        "draftPrs": safe_provider_list(list_my_draft_prs),
        "reviewRequests": safe_provider_list(list_prs_waiting_for_review),
    }


def safe_provider_list(fn):
    try:
        return fn()
    except Exception as exc:
        return {"ok": False, "items": [], "error": str(exc)}


def list_assigned_jira() -> dict[str, Any]:
    if _fake_providers_enabled():
        return {"ok": True, "items": [
            {
                "key": "IR-1427",
                "title": "Improve onboarding flow performance",
                "status": "In Progress",
                "url": "https://example.atlassian.net/browse/IR-1427",
            },
            {
                "key": "IR-1398",
                "title": "Fix issue with API rate limit handling",
                "status": "In Review",
                "url": "https://example.atlassian.net/browse/IR-1398",
            },
            {
                "key": "IR-1361",
                "title": "Add audit log for admin actions",
                "status": "To Do",
                "url": "https://example.atlassian.net/browse/IR-1361",
            },
            {
                "key": "IR-1310",
                "title": "Refactor user service error handling",
                "status": "Backlog",
                "url": "https://example.atlassian.net/browse/IR-1310",
            },
            {
                "key": "IR-1287",
                "title": "Add dark mode support to dashboard",
                "status": "Blocked",
                "url": "https://example.atlassian.net/browse/IR-1287",
            },
        ]}
    tickets = jira_routes.fetch_assigned_tickets(limit=100)
    return {"ok": True, "items": tickets}


def find_jira_ticket(query: str) -> dict[str, Any] | None:
    key = jira_routes.extract_jira_key(query)
    if not key:
        return None
    try:
        return jira_routes.fetch_ticket(key=key)
    except jira_routes.JiraRouteError as exc:
        raise OrchestratorV2RouteError(str(exc), exc.status) from exc


def list_my_open_prs() -> dict[str, Any]:
    prs = _run_gh_pr_list(["search", "prs", "--author", "@me", "--state", "open", "--sort", "updated", "--limit", "100"])
    return {"ok": True, "items": prs}


def list_my_draft_prs() -> dict[str, Any]:
    prs = _run_gh_pr_list(["search", "prs", "--author", "@me", "--state", "open", "--draft", "--sort", "updated", "--limit", "100"])
    prs = [pr for pr in prs if pr.get("isDraft")]
    return {"ok": True, "items": prs}


def list_prs_waiting_for_review() -> dict[str, Any]:
    return {"ok": True, "items": _run_gh_pr_list(["search", "prs", "--review-requested", "@me", "--state", "open"])}


def list_pr_review_requests(args: dict[str, Any] | None = None) -> dict[str, Any]:
    args = args or {}
    repo_name = pr_reviews.normalize_repo(args.get("repo") or args.get("repository") or pr_reviews.DEFAULT_REPO)
    try:
        limit = int(str(args.get("limit") or 20))
    except (TypeError, ValueError) as exc:
        raise OrchestratorV2RouteError("invalid limit", 400) from exc
    items = pr_reviews.list_review_requests(
        repo=repo_name,
        limit=limit,
        fake=_fake_providers_enabled(),
    )
    return {"repository": repo_name, "items": items, "pullRequests": items}


def start_pr_review(repo: v2.V2Repository, args: dict[str, Any], *, actor: str = "agent") -> dict[str, Any]:
    pull_request = args.get("pullRequest") if isinstance(args.get("pullRequest"), dict) else None
    number = args.get("number") or args.get("prNumber") or (pull_request or {}).get("number")
    repo_name = pr_reviews.normalize_repo(args.get("repo") or args.get("repository") or pr_reviews.DEFAULT_REPO)
    project_dir = str(args.get("projectDir") or args.get("workspaceDir") or pr_reviews.DEFAULT_PROJECT_DIR)
    review_cli = pr_reviews.normalize_review_cli(args.get("reviewCli") or args.get("cli") or pr_reviews.DEFAULT_REVIEW_CLI)
    launched = pr_reviews.launch_review_workspace(
        number=number,
        repo=repo_name,
        project_dir=project_dir,
        review_cli=review_cli,
        pull_request=pull_request,
        title=str(args.get("title") or "").strip() or None,
        cmux=get_cmux_cli(),
        fake=_fake_providers_enabled(),
    )
    session = launched["cmuxSession"]
    pr = dict(launched["pullRequest"])
    pr["isPrimary"] = True
    repo.record_cmux_snapshots([session])

    task_id = str(args.get("taskId") or "").strip()
    if task_id:
        repo.attach_pr(task_id, pr, actor=actor)
        repo.attach_cmux_session(task_id, session, launch_type=launched["launchType"], actor=actor)
        task = repo.update_task(task_id, {"status": args.get("status") or "Running"}, actor=actor)
    else:
        pr_target = pr.get("url") or f"{repo_name}#{pr['number']}"
        task = repo.create_task(
            {
                "title": str(args.get("taskTitle") or "").strip() or f"PR Review #{pr['number']}: {pr['title']}",
                "workspaceDir": launched["projectDir"],
                "status": args.get("status") or "Running",
                "priority": args.get("priority") or "Medium",
                "description": str(args.get("description") or "").strip() or f"Remote PR review for {pr_target}",
                "sessionLaunchType": launched["launchType"],
                "tags": args.get("tags") or [
                    {"tag": "PR Review", "color": "indigo"},
                    {"tag": review_cli, "color": ""},
                ],
                "pullRequest": pr,
            },
            cmux_session=session,
            actor=actor,
        )

    return {
        "task": task,
        "cmuxSession": session,
        "pullRequest": launched["pullRequest"],
        "repository": repo_name,
        "reviewCli": launched["reviewCli"],
        "launchType": launched["launchType"],
        "projectDir": launched["projectDir"],
        "prompt": launched["prompt"],
        "command": launched["command"],
    }


def find_task_session_link(repo: v2.V2Repository, workspace_id: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    for task in repo.list_tasks(include_history=True):
        for link in task.get("cmuxSessionLinks", []):
            if str(link.get("workspaceId") or "") == workspace_id:
                return task, link
    return None, None


def kill_cmux_session_now(repo: v2.V2Repository, workspace_id: str, args: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
    workspace_id = str(workspace_id or args.get("workspaceId") or "").strip()
    if not workspace_id:
        raise OrchestratorV2RouteError("workspaceId required", 400)
    run_id = str(args.get("runId") or v2.safe_id("lifecycle"))
    task, link = find_task_session_link(repo, workspace_id)
    result = get_cmux_cli().close_session(workspace_id)
    if task is not None and link is not None and _parse_bool(args.get("detachLink", True)):
        try:
            repo.detach_cmux_session(task["id"], link["id"], actor=actor)
        except v2.V2StorageError:
            pass
    repo.record_tool_run(run_id, "kill_cmux_session.execute", {"workspaceId": workspace_id}, result, actor=actor)
    repo.record_activity_event(
        "cmux_session_killed",
        f"Stopped cmux session {workspace_id}",
        str((task or {}).get("title") or ""),
        target_type="cmux_session",
        target_id=workspace_id,
        run_id=run_id,
    )
    return {"result": result, "workspaceId": workspace_id, "taskId": (task or {}).get("id")}


def restart_cmux_session_now(repo: v2.V2Repository, workspace_id: str, args: dict[str, Any], *, actor: str = "local") -> dict[str, Any]:
    workspace_id = str(workspace_id or args.get("workspaceId") or "").strip()
    if not workspace_id:
        raise OrchestratorV2RouteError("workspaceId required", 400)
    run_id = str(args.get("runId") or v2.safe_id("lifecycle"))
    task, link = find_task_session_link(repo, workspace_id)
    launch_type = v2.normalize_launch_type(args.get("launchType") or (link or {}).get("launchType"))
    title = str(args.get("title") or (link or {}).get("title") or "").strip()
    cwd = str(
        args.get("workspaceDir")
        or args.get("cwd")
        or (link or {}).get("cwd")
        or (task or {}).get("workspaceDir")
        or ""
    ).strip()
    result = get_cmux_cli().restart_session(workspace_id, title=title, cwd=cwd, launch_type=launch_type)
    session = result.get("session") if isinstance(result.get("session"), dict) else {}
    new_link = None
    if task is not None and session.get("workspaceId"):
        if link is not None:
            try:
                repo.detach_cmux_session(task["id"], link["id"], actor=actor)
            except v2.V2StorageError:
                pass
        new_link = repo.attach_cmux_session(task["id"], session, launch_type=launch_type, actor=actor)
    if session:
        repo.record_cmux_snapshots([session])
    repo.record_tool_run(
        run_id,
        "restart_cmux_session.execute",
        {"workspaceId": workspace_id, "launchType": launch_type},
        {"session": session, "previousWorkspaceId": workspace_id},
        actor=actor,
    )
    repo.record_activity_event(
        "cmux_session_restarted",
        f"Restarted cmux session {workspace_id}",
        str(session.get("workspaceId") or ""),
        target_type="cmux_session",
        target_id=str(session.get("workspaceId") or workspace_id),
        run_id=run_id,
    )
    return {
        "result": result,
        "session": session,
        "cmuxSessionLink": new_link,
        "previousWorkspaceId": workspace_id,
        "taskId": (task or {}).get("id"),
    }


def cmux_lifecycle_approval_payload(tool_name: str, args: dict[str, Any], *, run_id: str) -> dict[str, Any]:
    workspace_id = str(args.get("workspaceId") or "").strip()
    if not workspace_id:
        raise OrchestratorV2RouteError("workspaceId required", 400)
    action = "Stop" if tool_name == "kill_cmux_session" else "Restart"
    return {
        "runId": run_id,
        "taskId": str(args.get("taskId") or "").strip() or None,
        "kind": tool_name,
        "title": f"{action} cmux session {workspace_id}",
        "summary": str(args.get("reason") or f"The agent wants to {action.lower()} cmux session {workspace_id}."),
        "impact": "Session lifecycle",
        "payload": {
            "runId": run_id,
            "toolName": tool_name,
            "workspaceId": workspace_id,
            "launchType": args.get("launchType"),
            "workspaceDir": args.get("workspaceDir") or args.get("cwd"),
            "title": args.get("title"),
            "requestedAction": f"{action} cmux session",
            "reversible": tool_name == "restart_cmux_session",
        },
    }


def _run_gh_pr_list(args: list[str]) -> list[dict[str, Any]]:
    if _fake_providers_enabled():
        prs = [
            {
                "number": 4821,
                "title": "Fix onboarding race condition",
                "url": "https://github.com/orchestrate-ai/orchestrate-ai/pull/4821",
                "branch": "feature/onboarding-fix",
                "isDraft": False,
                "state": "OPEN",
                "owner": "orchestrate-ai",
                "repo": "orchestrate-ai",
                "author": "ronnie",
                "raw": {"fake": True},
            },
            {
                "number": 4817,
                "title": "Add audit log service",
                "url": "https://github.com/orchestrate-ai/orchestrate-ai/pull/4817",
                "branch": "feature/audit-log",
                "isDraft": False,
                "state": "OPEN",
                "owner": "orchestrate-ai",
                "repo": "orchestrate-ai",
                "author": "ronnie",
                "raw": {"fake": True},
            },
            {
                "number": 4811,
                "title": "Refactor user repo",
                "url": "https://github.com/orchestrate-ai/orchestrate-ai/pull/4811",
                "branch": "refactor/user-repo",
                "isDraft": False,
                "state": "OPEN",
                "owner": "orchestrate-ai",
                "repo": "orchestrate-ai",
                "author": "ronnie",
                "raw": {"fake": True},
            },
            {
                "number": 4799,
                "title": "Update rate limit middleware",
                "url": "https://github.com/orchestrate-ai/orchestrate-ai/pull/4799",
                "branch": "feature/rate-limit",
                "isDraft": False,
                "state": "OPEN",
                "owner": "orchestrate-ai",
                "repo": "orchestrate-ai",
                "author": "ronnie",
                "raw": {"fake": True},
            },
        ]
        if args[:1] == ["search"]:
            return []
        return prs
    json_fields = "number,title,url,isDraft,state,author,repository"
    if args[:1] != ["search"]:
        json_fields = f"{json_fields},headRefName"
    command = ["gh", *args, "--json", json_fields]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
    except FileNotFoundError as exc:
        raise OrchestratorV2RouteError("gh is not installed or is not on PATH", 500) from exc
    except subprocess.TimeoutExpired as exc:
        raise OrchestratorV2RouteError("GitHub request timed out", 504) from exc
    except OSError as exc:
        raise OrchestratorV2RouteError(f"GitHub request failed: {exc}", 500) from exc
    if result.returncode != 0:
        raise OrchestratorV2RouteError((result.stderr or result.stdout or "GitHub request failed").strip(), 502)
    try:
        payload = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise OrchestratorV2RouteError("GitHub returned invalid JSON", 502) from exc
    if not isinstance(payload, list):
        raise OrchestratorV2RouteError("GitHub returned an unexpected response", 502)
    return [normalize_pr(item) for item in payload if isinstance(item, dict)]


def choose_project_folder(data: dict[str, Any]) -> str:
    prompt = str(data.get("prompt") or "Select project folder").replace('"', "'")
    current_path = str(data.get("currentPath") or data.get("path") or "").strip()
    script = f'POSIX path of (choose folder with prompt "{prompt}"'
    if current_path and os.path.isdir(os.path.expanduser(current_path)):
        script += f' default location POSIX file "{os.path.expanduser(current_path)}"'
    script += ")"
    try:
        result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=120, check=False)
    except FileNotFoundError as exc:
        raise OrchestratorV2RouteError("macOS folder picker is unavailable", 501) from exc
    except subprocess.TimeoutExpired as exc:
        raise OrchestratorV2RouteError("folder picker timed out", 504) from exc
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Folder selection cancelled").strip()
        if "User canceled" in message:
            raise OrchestratorV2RouteError("Folder selection cancelled", 499)
        raise OrchestratorV2RouteError(redact_text(message), 500)
    return str(result.stdout or "").strip()


def session_cwd(session: dict[str, Any]) -> str:
    raw = session.get("raw") if isinstance(session.get("raw"), dict) else {}
    workspace = raw.get("workspace") if isinstance(raw.get("workspace"), dict) else {}
    return str(
        session.get("cwd")
        or session.get("currentDirectory")
        or workspace.get("current_directory")
        or workspace.get("cwd")
        or ""
    ).strip()


def _fake_providers_enabled() -> bool:
    return os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_PROVIDERS", "").strip().lower() in {"1", "true", "yes", "on"}


def normalize_pr(item: dict[str, Any]) -> dict[str, Any]:
    repo = item.get("repository") if isinstance(item.get("repository"), dict) else {}
    owner = repo.get("owner") if isinstance(repo.get("owner"), dict) else {}
    author = item.get("author") if isinstance(item.get("author"), dict) else {}
    name_with_owner = str(repo.get("nameWithOwner") or repo.get("name_with_owner") or "")
    split_owner, _, split_repo = name_with_owner.partition("/")
    return {
        "number": item.get("number"),
        "title": str(item.get("title") or ""),
        "url": str(item.get("url") or ""),
        "branch": str(item.get("headRefName") or ""),
        "isDraft": bool(item.get("isDraft")),
        "state": str(item.get("state") or ""),
        "owner": str(owner.get("login") or repo.get("owner") or split_owner or ""),
        "repo": str(repo.get("name") or split_repo or ""),
        "author": str(author.get("login") or ""),
        "raw": item,
    }


_LAST_WATCHER_SNAPSHOT: dict[str, Any] = {"sessionStates": {}, "orphanKeys": set()}


def run_watcher_once(*, repo: v2.V2Repository) -> dict[str, Any]:
    run_id = v2.safe_id("watch")
    sessions: list[dict[str, Any]] = []
    session_error = ""
    provider_results: dict[str, Any] = {}
    for name, fn in [
        ("list_assigned_jira", list_assigned_jira),
        ("list_my_open_prs", list_my_open_prs),
        ("list_my_draft_prs", list_my_draft_prs),
        ("list_prs_waiting_for_review", list_prs_waiting_for_review),
    ]:
        try:
            value = fn()
            provider_results[name] = value
            repo.record_tool_run(run_id, name, {"watcher": True}, value, actor="watcher")
        except Exception as exc:
            provider_results[name] = {"ok": False, "error": redact_text(exc)}
            repo.record_tool_run(run_id, name, {"watcher": True}, provider_results[name], actor="watcher", status="error")
    try:
        sessions = get_cmux_cli().list_sessions()
        orphans = repo.record_cmux_snapshots(sessions)
    except Exception as exc:
        session_error = str(exc)
        orphans = repo.list_orphans()
    inspections: list[dict[str, Any]] = []
    for session in sessions[:30]:
        try:
            screen = get_cmux_cli().read_session(str(session.get("workspaceId") or ""), str(session.get("surfaceId") or ""), lines=80)
        except Exception:
            screen = ""
        try:
            inspections.append(get_cmux_cli().inspect_session(session, screen_text=screen))
        except Exception as exc:
            inspections.append({"workspaceId": session.get("workspaceId", ""), "error": redact_text(exc)})
    state_changes = detect_watcher_changes(repo, run_id, inspections, orphans)
    refreshed_summaries = 0
    for task in repo.list_tasks():
        texts = []
        for link in task.get("cmuxSessionLinks", []):
            try:
                texts.append(get_cmux_cli().read_session(link["workspaceId"], link.get("surfaceId", ""), lines=160))
            except Exception:
                continue
        if texts:
            repo.summarize_task_sessions(task["id"], texts)
            refreshed_summaries += 1
    repo.record_tool_run(
        run_id,
        "proactive_watcher",
        {"manual": True},
        {
            "sessions": len(sessions),
            "orphans": len(orphans),
            "inspections": inspections,
            "refreshedSummaries": refreshed_summaries,
            "sessionError": session_error,
            "providers": provider_results,
        },
        actor="watcher",
    )
    return {
        "runId": run_id,
        "sessions": sessions,
        "orphans": orphans,
        "inspections": inspections,
        "refreshedSummaries": refreshed_summaries,
        "providerResults": provider_results,
        "sessionError": session_error,
        "stateChanges": state_changes,
    }


def detect_watcher_changes(
    repo: v2.V2Repository,
    run_id: str,
    inspections: list[dict[str, Any]],
    orphans: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Compare this watcher pass against the previous one and narrate meaningful
    transitions (session state changes, new orphans) as activity events."""
    previous_states: dict[str, str] = dict(_LAST_WATCHER_SNAPSHOT.get("sessionStates") or {})
    previous_orphans: set[str] = set(_LAST_WATCHER_SNAPSHOT.get("orphanKeys") or set())
    changes: list[dict[str, Any]] = []
    current_states: dict[str, str] = {}
    for inspection in inspections:
        workspace_id = str(inspection.get("workspaceId") or "")
        if not workspace_id or inspection.get("error"):
            continue
        state = str(inspection.get("state") or "unknown")
        current_states[workspace_id] = state
        before = previous_states.get(workspace_id)
        if before is not None and before != state:
            change = {
                "kind": "session_state_changed",
                "workspaceId": workspace_id,
                "from": before,
                "to": state,
                "title": str(inspection.get("title") or workspace_id),
            }
            changes.append(change)
            label = {
                "error": "needs attention",
                "running_tool": "started running a tool",
                "completed_recently": "finished recent work",
                "idle": "went idle",
            }.get(state, state)
            repo.record_activity_event(
                "session_state_changed",
                f"{change['title']} {label}",
                f"{before} -> {state}",
                target_type="cmux_session",
                target_id=workspace_id,
                run_id=run_id,
                payload=change,
            )
    current_orphans = {str(orphan.get("sessionKey") or "") for orphan in orphans if orphan.get("sessionKey")}
    for key in sorted(current_orphans - previous_orphans):
        orphan = next((item for item in orphans if str(item.get("sessionKey") or "") == key), {})
        changes.append({"kind": "orphan_detected", "sessionKey": key})
        repo.record_activity_event(
            "orphan_detected",
            f"New unlinked cmux session: {orphan.get('title') or orphan.get('workspaceId') or key}",
            str(orphan.get("cwd") or ""),
            target_type="cmux_session",
            target_id=str(orphan.get("workspaceId") or key),
            run_id=run_id,
        )
    if changes:
        repo.record_activity_event(
            "watcher_summary",
            f"Watcher detected {len(changes)} change(s)",
            ", ".join(sorted({change["kind"] for change in changes})),
            target_type="watcher_run",
            target_id=run_id,
            run_id=run_id,
            payload={"changes": changes},
        )
    _LAST_WATCHER_SNAPSHOT["sessionStates"] = current_states
    _LAST_WATCHER_SNAPSHOT["orphanKeys"] = current_orphans
    return changes


def handle_chat_turn(repo: v2.V2Repository, data: dict[str, Any]) -> dict[str, Any]:
    run_id = str(data.get("runId") or v2.safe_id("chatrun"))
    raw_messages = data.get("messages")
    user_text = str(data.get("message") or "")
    if isinstance(raw_messages, list) and raw_messages:
        last = raw_messages[-1]
        if isinstance(last, dict):
            user_text = str(last.get("content") or last.get("text") or user_text)
    if user_text:
        repo.append_chat_message("user", user_text, {"runId": run_id})
    tasks = find_tasks_for_agent_query(repo, user_text)
    if tasks:
        lines = []
        for task in tasks[:5]:
            line = f"{task['title']} is {task['status']} ({task['priority']})"
            if task.get("sessionSummary"):
                line += f" — {task['sessionSummary']['summary']}"
            lines.append(line)
        answer = "Current task status:\n" + "\n".join(f"- {line}" for line in lines)
    else:
        all_tasks = repo.list_tasks()
        answer = f"I found {len(all_tasks)} active task(s). Ask by title, Jira key, PR number, or session id for a narrower status read."
    repo.append_chat_message("assistant", answer, {"runId": run_id, "groundedIn": "sqlite-tasks"})
    repo.record_tool_run(run_id, "list_tasks", {"query": user_text}, {"count": len(tasks)}, actor="agent")
    return {"runId": run_id, "message": {"role": "assistant", "content": answer}, "tasks": tasks}


def find_tasks_for_agent_query(repo: v2.V2Repository, text: str) -> list[dict[str, Any]]:
    seen: set[str] = set()
    results: list[dict[str, Any]] = []
    for query in _agent_search_queries(text):
        for task in repo.list_tasks(include_history=True, query=query):
            task_id = str(task.get("id") or "")
            if task_id and task_id not in seen:
                seen.add(task_id)
                results.append(task)
    return results


def _agent_search_queries(text: str) -> list[str]:
    value = str(text or "").strip()
    queries: list[str] = []
    if value:
        queries.append(value)
    jira_key = jira_routes.extract_jira_key(value)
    if jira_key:
        queries.append(jira_key)
    for match in re.finditer(r"(?:pr|pull request)\s*#?\s*(\d+)|#(\d+)", value, flags=re.IGNORECASE):
        queries.append(match.group(1) or match.group(2))
    for token in re.findall(r"[A-Za-z0-9_.:-]{3,}", value):
        normalized = token.strip(".,;:()[]{}").lower()
        if normalized in {"status", "task", "tasks", "what", "show", "tell", "about", "please", "current"}:
            continue
        queries.append(token)
    deduped: list[str] = []
    for query in queries:
        clean = str(query or "").strip()
        if clean and clean.casefold() not in {item.casefold() for item in deduped}:
            deduped.append(clean)
    return deduped


def run_agent_tool(repo: v2.V2Repository, tool_name: str, data: dict[str, Any], *, engine) -> Any:
    run_id = str(data.get("runId") or v2.safe_id("toolrun"))
    args = data.get("args") if isinstance(data.get("args"), dict) else data
    tool_status = "completed"
    requires_approval = False
    if tool_name == "list_tasks":
        result = {"tasks": repo.list_tasks(include_history=bool(args.get("includeHistory")), query=str(args.get("q") or ""))}
    elif tool_name == "get_task":
        task = repo.get_task(str(args.get("taskId") or args.get("id") or ""))
        result = {"task": task}
    elif tool_name == "search_tasks":
        result = {"tasks": repo.list_tasks(include_history=True, query=str(args.get("q") or args.get("query") or ""))}
    elif tool_name == "list_cmux_sessions":
        sessions = get_cmux_cli().list_sessions()
        repo.record_cmux_snapshots(sessions)
        result = {"sessions": sessions}
    elif tool_name == "read_cmux_session":
        result = {"screen": get_cmux_cli().read_session(str(args.get("workspaceId") or ""), str(args.get("surfaceId") or ""), lines=int(args.get("lines") or 200))}
    elif tool_name == "search_cmux_sessions":
        result = {"matches": get_cmux_cli().search_sessions(str(args.get("query") or ""))}
    elif tool_name == "inspect_cmux_session":
        session = args.get("session") if isinstance(args.get("session"), dict) else args
        screen = str(args.get("screen") or "")
        if not screen and session.get("workspaceId"):
            try:
                screen = get_cmux_cli().read_session(str(session.get("workspaceId") or ""), str(session.get("surfaceId") or ""), lines=int(args.get("lines") or 120))
            except cmux_cli.CmuxCliError:
                screen = ""
        result = get_cmux_cli().inspect_session(session, screen_text=screen)
        result["screenExcerpt"] = "\n".join(screen.splitlines()[-20:])
    elif tool_name == "summarize_task_sessions":
        result = repo.summarize_task_sessions(str(args.get("taskId") or ""), [str(item) for item in args.get("sessionTexts") or []])
    elif tool_name == "read_goal_markdown":
        result = {"goal": repo.read_goal(str(args.get("taskId") or ""))}
    elif tool_name == "find_jira_ticket":
        result = {"ticket": find_jira_ticket(str(args.get("query") or args.get("key") or ""))}
    elif tool_name == "list_assigned_jira":
        result = list_assigned_jira()
    elif tool_name == "list_my_open_prs":
        result = list_my_open_prs()
    elif tool_name == "list_my_draft_prs":
        result = list_my_draft_prs()
    elif tool_name == "list_prs_waiting_for_review":
        result = list_prs_waiting_for_review()
    elif tool_name == "list_pr_review_requests":
        result = list_pr_review_requests(args)
    elif tool_name == "start_pr_review":
        result = start_pr_review(repo, args, actor="agent")
    elif tool_name == "get_git_status":
        result = fake_git_status() if _fake_providers_enabled() else engine.get_git_status_for_path(_resolve_body_path(args))
    elif tool_name == "get_git_diff":
        result = {"diff": read_git_diff(engine, _resolve_body_path(args), str(args.get("file") or ""), str(args.get("section") or "unstaged"))}
    elif tool_name == "create_task":
        workspace_dir = str(args.get("workspaceDir") or "").strip()
        launch_type = v2.normalize_launch_type(args.get("sessionLaunchType") or args.get("launchType"))
        session = get_cmux_cli().create_session(title=str(args.get("title") or "New Task"), cwd=workspace_dir, launch_type=launch_type)
        result = {"task": repo.create_task(args, cmux_session=session, actor="agent")}
    elif tool_name == "update_task_status":
        result = {"task": repo.update_task(str(args.get("taskId") or ""), {"status": args.get("status")}, actor="agent")}
    elif tool_name == "update_task_priority":
        result = {"task": repo.update_task(str(args.get("taskId") or ""), {"priority": args.get("priority")}, actor="agent")}
    elif tool_name == "update_task_tags":
        result = {"task": repo.update_task(str(args.get("taskId") or ""), {"tags": args.get("tags") or []}, actor="agent")}
    elif tool_name == "attach_jira_to_task":
        result = {"jiraLink": repo.attach_jira(str(args.get("taskId") or ""), args.get("ticket") or args, actor="agent")}
    elif tool_name == "attach_pr_to_task":
        result = {"pullRequestLink": repo.attach_pr(str(args.get("taskId") or ""), args.get("pullRequest") or args, actor="agent")}
    elif tool_name == "attach_cmux_session_to_task":
        result = {"cmuxSessionLink": repo.attach_cmux_session(str(args.get("taskId") or ""), args.get("session") or args, actor="agent")}
    elif tool_name == "detach_cmux_session_from_task":
        repo.detach_cmux_session(str(args.get("taskId") or ""), str(args.get("linkId") or ""), actor="agent")
        result = {"ok": True}
    elif tool_name == "create_cmux_session":
        result = {"session": get_cmux_cli().create_session(title=str(args.get("title") or "New Session"), cwd=str(args.get("workspaceDir") or args.get("cwd") or ""), launch_type=v2.normalize_launch_type(args.get("launchType")))}
    elif tool_name == "launch_coding_agent":
        result = {"session": get_cmux_cli().create_session(title=str(args.get("title") or "Agent Session"), cwd=str(args.get("workspaceDir") or args.get("cwd") or ""), launch_type=v2.normalize_launch_type(args.get("launchType")))}
    elif tool_name == "send_cmux_prompt":
        result = get_cmux_cli().send_text(str(args.get("workspaceId") or ""), str(args.get("prompt") or ""), surface_id=str(args.get("surfaceId") or ""))
    elif tool_name == "send_cmux_key":
        result = get_cmux_cli().send_key(str(args.get("workspaceId") or ""), str(args.get("key") or ""), surface_id=str(args.get("surfaceId") or ""))
    elif tool_name == "update_goal_markdown":
        result = {"goal": repo.update_goal(str(args.get("taskId") or ""), str(args.get("content") or ""), actor="agent")}
    elif tool_name == "create_approval_request":
        result = {"approval": repo.create_approval_request(args, actor="agent")}
    elif tool_name == "post_jira_comment":
        approval_payload = jira_comment_approval_payload(args, run_id=run_id)
        result = {"approval": repo.create_approval_request(approval_payload, actor="agent")}
        tool_status = "requires_approval"
        requires_approval = True
    elif tool_name == "transition_jira_status":
        key = str(args.get("key") or args.get("issueKey") or "").strip()
        target_status = str(args.get("status") or args.get("targetStatus") or "").strip()
        transition = jira_routes.transition_status(key=key, status=target_status)
        result = {"transition": transition, "key": key.upper(), "targetStatus": target_status}
    elif tool_name in {"kill_cmux_session", "restart_cmux_session"}:
        approval_payload = cmux_lifecycle_approval_payload(tool_name, args, run_id=run_id)
        result = {"approval": repo.create_approval_request(approval_payload, actor="agent")}
        tool_status = "requires_approval"
        requires_approval = True
    elif tool_name in {
        "post_pr_reply",
        "submit_pr_review",
        "run_destructive_git_operation",
    }:
        result = not_implemented_result(tool_name)
        tool_status = "not_implemented"
    else:
        raise OrchestratorV2RouteError(f"unknown agent tool: {tool_name}", 404)
    repo.record_tool_run(run_id, tool_name, args, result, actor="agent", status=tool_status, requires_approval=requires_approval)
    return result


def jira_comment_approval_payload(args: dict[str, Any], *, run_id: str) -> dict[str, Any]:
    key = str(args.get("key") or args.get("issueKey") or "").strip().upper()
    body = str(args.get("body") or args.get("comment") or "").strip()
    if not key:
        raise OrchestratorV2RouteError("Jira key required", 400)
    if not body:
        raise OrchestratorV2RouteError("Jira comment body required", 400)
    return {
        "runId": run_id,
        "taskId": str(args.get("taskId") or "").strip() or None,
        "kind": "post_jira_comment",
        "title": f"Post Jira comment on {key}",
        "summary": body,
        "impact": "External write",
        "payload": {
            "runId": run_id,
            "toolName": "post_jira_comment",
            "key": key,
            "body": body,
            "requestedAction": "Post Jira comment",
            "reversible": False,
        },
    }


def not_implemented_result(tool_name: str) -> dict[str, Any]:
    messages = {
        "post_pr_reply": "PR replies are not implemented in this production pass.",
        "submit_pr_review": "PR reviews are not implemented in this production pass.",
        "run_destructive_git_operation": "Destructive git operations are not implemented in this production pass.",
    }
    return {
        "ok": False,
        "status": "not_implemented",
        "capability": tool_name,
        "message": messages.get(tool_name, f"{tool_name} is not implemented."),
        "suggestedNextStep": "Track this as a future Orchestrator V2 capability instead of simulating success.",
    }


def execute_approved_payload(repo: v2.V2Repository, before: dict[str, Any] | None, approval: dict[str, Any]) -> dict[str, Any] | None:
    stored = before or approval
    if not stored:
        return None
    kind = str(stored.get("kind") or "")
    payload = stored.get("payload") if isinstance(stored.get("payload"), dict) else {}
    run_id = str(payload.get("runId") or stored.get("runId") or approval.get("id") or "")
    if kind == "post_jira_comment":
        key = str(payload.get("key") or "").strip().upper()
        body = str(payload.get("body") or "").strip()
        if not key or not body:
            return {"tool": "post_jira_comment", "status": "skipped", "reason": "stored reviewed payload is incomplete"}
        result = jira_routes.post_comment(key=key, body=body)
        repo.record_tool_run(
            run_id,
            "post_jira_comment.execute",
            {"approvalId": approval.get("id"), "key": key, "body": body},
            {"result": result, "key": key},
            actor="agent",
        )
        return {"tool": "post_jira_comment", "key": key, "result": result}
    if kind in {"kill_cmux_session", "restart_cmux_session"}:
        workspace_id = str(payload.get("workspaceId") or "").strip()
        if not workspace_id:
            return {"tool": kind, "status": "skipped", "reason": "stored reviewed payload is incomplete"}
        args = {**payload, "runId": run_id}
        try:
            if kind == "kill_cmux_session":
                execution = kill_cmux_session_now(repo, workspace_id, args, actor="agent")
            else:
                execution = restart_cmux_session_now(repo, workspace_id, args, actor="agent")
        except (cmux_cli.CmuxCliError, OrchestratorV2RouteError, v2.V2StorageError) as exc:
            repo.record_tool_run(
                run_id,
                f"{kind}.execute",
                {"approvalId": approval.get("id"), "workspaceId": workspace_id},
                {"error": str(exc)},
                actor="agent",
                status="error",
            )
            return {"tool": kind, "status": "error", "error": str(exc), "workspaceId": workspace_id}
        return {"tool": kind, "workspaceId": workspace_id, **execution}
    return None


def read_git_diff(engine, cwd: str, file: str, section: str) -> str:
    if _fake_providers_enabled():
        return fake_git_diff(file)
    if not cwd or not os.path.isdir(cwd):
        raise OrchestratorV2RouteError("path required", 400)
    if not file:
        raise OrchestratorV2RouteError("file required", 400)
    full_path = os.path.join(cwd, file)
    if section == "untracked" and os.path.islink(full_path) and os.path.isdir(full_path):
        raise OrchestratorV2RouteError("untracked directory symlinks cannot be diffed", 400)
    if section == "untracked" and os.path.isdir(full_path):
        parts = []
        for root, _dirs, files in os.walk(full_path):
            for fname in sorted(files):
                fpath = os.path.relpath(os.path.join(root, fname), cwd)
                part = engine._run_git_command(cwd, ["diff", "--no-index", "--", "/dev/null", fpath], max_bytes=100 * 1024)
                if not part.startswith("[error]"):
                    parts.append(part)
        return "\n".join(parts) if parts else "(empty directory)"
    if section == "staged":
        args = ["diff", "--cached", "--", file]
    elif section == "untracked":
        args = ["diff", "--no-index", "--", "/dev/null", file]
    else:
        args = ["diff", "--", file]
    result = engine._run_git_command(cwd, args, max_bytes=100 * 1024)
    if result.startswith("[error]"):
        raise OrchestratorV2RouteError(result, 500)
    return result


def read_git_commit_files(engine, cwd: str, commit_hash: str) -> list[dict[str, str]]:
    if _fake_providers_enabled():
        return [
            {"status": "M", "file": "app/services/rate_limiter.rb"},
            {"status": "A", "file": "spec/services/rate_limiter_spec.rb"},
            {"status": "D", "file": "docs/legacy_rate_limit.md"},
        ]
    if not cwd or not os.path.isdir(cwd):
        raise OrchestratorV2RouteError("path required", 400)
    result = engine._run_git_command(
        cwd,
        [
            "diff-tree",
            "--diff-merges=first-parent",
            "--root",
            "--no-commit-id",
            "--name-status",
            "-r",
            "-z",
            commit_hash,
        ],
    )
    if result.startswith("[error]"):
        raise OrchestratorV2RouteError(result, 500)
    return engine._parse_git_name_status_z(result)


def read_git_commit_diff(engine, cwd: str, commit_hash: str, file: str) -> str:
    if _fake_providers_enabled():
        return fake_git_diff(file)
    if not cwd or not os.path.isdir(cwd):
        raise OrchestratorV2RouteError("path required", 400)
    result = engine._run_git_command(cwd, ["diff", f"{commit_hash}~1", commit_hash, "--", file], max_bytes=50 * 1024)
    if result.startswith("[error]"):
        result = engine._run_git_command(cwd, ["show", commit_hash, "--", file], max_bytes=50 * 1024)
    if result.startswith("[error]"):
        raise OrchestratorV2RouteError(result, 500)
    return result


def update_git_index(engine, data: dict[str, Any], *, stage: bool) -> dict[str, Any]:
    target = _resolve_body_path(data)
    file = str(data.get("file") or "").strip()
    if not file:
        raise OrchestratorV2RouteError("file required", 400)
    files = engine._git_action_paths(target, file, stage=stage)
    args = ["add", "--", *files] if stage else ["reset", "--", *files]
    result = engine._run_git_command(target, args)
    if result.startswith("[error]"):
        raise OrchestratorV2RouteError(result, 500)
    return {"path": target, "file": file, "action": "stage" if stage else "unstage"}


def open_native_file(data: dict[str, Any]) -> dict[str, Any]:
    file = str(data.get("file") or "").strip()
    if file:
        target = _resolve_body_path(data)
        full_path = os.path.realpath(os.path.join(target, file))
        try:
            if os.path.commonpath([target, full_path]) != target:
                raise OrchestratorV2RouteError("invalid file path", 400)
        except ValueError as exc:
            raise OrchestratorV2RouteError("invalid file path", 400) from exc
    else:
        raw_path = str(data.get("path") or "").strip()
        if not raw_path:
            raise OrchestratorV2RouteError("path required", 400)
        full_path = os.path.realpath(os.path.expanduser(raw_path))
    if not os.path.exists(full_path):
        raise OrchestratorV2RouteError(f"file not found: {full_path}", 404)
    try:
        subprocess.run(["open", full_path], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise OrchestratorV2RouteError(str(exc), 500) from exc
    return {"path": full_path}


def _validated_commit_hash(value: Any) -> str:
    commit_hash = str(value or "").strip()
    if not commit_hash:
        raise OrchestratorV2RouteError("hash required", 400)
    if not re.fullmatch(r"[0-9a-f]{4,40}", commit_hash, flags=re.IGNORECASE):
        raise OrchestratorV2RouteError("invalid hash", 400)
    return commit_hash


def fake_git_status() -> dict[str, Any]:
    commits = [
        {"hash": "a7fb847", "message": "Refactor rate limit service and add sliding window algorithm", "author": "Alex Kim", "date": "3 hours ago"},
        {"hash": "d77a3ab", "message": "Add audit log for rate limit events", "author": "Maya Chen", "date": "1 day ago"},
        {"hash": "c5bcf93", "message": "Extract Redis client to initializer", "author": "Jordan Lee", "date": "2 days ago"},
        {"hash": "7465ec7", "message": "Add rate limit metrics endpoint", "author": "Priya Shah", "date": "3 days ago"},
        {"hash": "f12b9d0", "message": "Initialize rate limiting implementation", "author": "Alex Kim", "date": "5 days ago"},
        {"hash": "a451d72", "message": "Document API service retry behavior", "author": "Alex Kim", "date": "6 days ago"},
        {"hash": "39bd4ca", "message": "Add request controller specs", "author": "Maya Chen", "date": "1 week ago"},
        {"hash": "7bd0ad5", "message": "Wire rate limit headers", "author": "Jordan Lee", "date": "1 week ago"},
        {"hash": "2a91e01", "message": "Add API policy object", "author": "Priya Shah", "date": "8 days ago"},
        {"hash": "d8be112", "message": "Clean up request middleware", "author": "Alex Kim", "date": "9 days ago"},
        {"hash": "1fe92ac", "message": "Add Redis connection helpers", "author": "Maya Chen", "date": "10 days ago"},
        {"hash": "6f40ad9", "message": "Baseline service module", "author": "Jordan Lee", "date": "11 days ago"},
    ]
    staged = [
        {"file": "app/services/rate_limiter.rb", "status": "M", "order": 12},
        {"file": "app/models/rate_limit.rb", "status": "A"},
        {"file": "config/initializers/rate_limit.rb", "status": "M"},
    ]
    modified = [
        {"file": "app/controllers/api/v1/requests_controller.rb", "status": "M"},
        {"file": "app/services/limit_counter.rb", "status": "M"},
        {"file": "lib/rate_limit/metrics.rb", "status": "M"},
        {"file": "docs/rate_limit.md", "status": "M"},
        {"file": "spec/services/rate_limiter_spec.rb", "status": "M"},
        {"file": "spec/controllers/api/v1/requests_controller_spec.rb", "status": "M"},
        {"file": "config/routes.rb", "status": "M"},
        {"file": "README.md", "status": "M"},
        {"file": "Gemfile", "status": "M"},
        {"file": "Gemfile.lock", "status": "M"},
        {"file": "app/services/rate_limit_window.rb", "status": "M"},
        {"file": "config/rate_limit.yml", "status": "M"},
        {"file": "spec/support/rate_limit_helpers.rb", "status": "M"},
        {"file": "app/policies/rate_limit_policy.rb", "status": "M"},
        {"file": "lib/rate_limit/violation.rb", "status": "A"},
        {"file": "spec/fixtures/rate_limit/user.json", "status": "A"},
        {"file": "app/jobs/old_rate_limit_cleanup_job.rb", "status": "D"},
        {"file": "docs/legacy_rate_limit.md", "status": "D"},
    ]
    untracked = [
        "spec/test_helpers/rate_limit_helper.rb",
        "scripts/backfill_rate_limits.rb",
        "tmp/rate_limit_notes.md",
    ]
    return {
        "branch": "feature/rate-limit",
        "commits": commits,
        "staged": staged,
        "unstaged": modified,
        "untracked": untracked,
    }


def fake_git_diff(file: str) -> str:
    target = file or "app/services/rate_limiter.rb"
    return f"""diff --git a/{target} b/{target}
index 8452885..8afe4d8 100644
--- a/{target}
+++ b/{target}
@@ -16,17 +16,28 @@ module Api
   class RateLimiter
     def initialize(redis: Redis.current)
       @redis = redis
     end
 
-    def allowed?(key, limit:, window:)
-      current = @redis.get(counter_key(key))
-      count = current ? current.to_i : 0
-      return true if count < limit
-      false
-    end
+    def allowed?(key, limit:, window:, strategy: :fixed)
+      case strategy
+      when :fixed
+        current = @redis.get(counter_key(key))
+        count = current ? current.to_i : 0
+        return false if count >= limit
+        true
+      when :sliding_window
+        now = Time.now.to_i
+        window_start = now - window
+        key_with_window = \"#{{counter_key(key)}}:#{{window_start}}\"
+        current = @redis.zcount(key_with_window, window_start, now)
+        return false if current >= limit
+        true
+      end
+    end
 
-    def increment(key)
-      @redis.incr(counter_key(key))
+    def increment(key, window:)
+      @redis.multi do |multi|
+        multi.incr(counter_key(key))
+        multi.expire(counter_key(key), window)
+      end
     end
   end
 end
"""


def _task_suffix(path: str) -> tuple[str, str]:
    raw = path[len("/api/orchestrator-v2/tasks/"):]
    if "/" not in raw:
        return urllib.parse.unquote(raw), ""
    task_id, suffix = raw.split("/", 1)
    return urllib.parse.unquote(task_id), "/" + suffix


def _resolve_path_param(params: dict[str, list[str]]) -> str:
    target = str(params.get("path", [""])[0] or "").strip()
    return _resolve_path_value(target)


def _resolve_body_path(data: dict[str, Any]) -> str:
    target = str(data.get("path") or data.get("workspaceDir") or data.get("cwd") or "").strip()
    return _resolve_path_value(target)


def _resolve_path_value(value: str) -> str:
    fake_root = os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_ROOT", "").strip()
    if fake_root and value.startswith("/workspaces/orchestrate-ai/"):
        suffix = value[len("/workspaces/orchestrate-ai/"):].strip("/")
        return os.path.realpath(os.path.join(fake_root, suffix))
    path = os.path.realpath(os.path.expanduser(value))
    if not value or not os.path.isdir(path):
        raise OrchestratorV2RouteError("path required", 400)
    return path


def _parse_bool(value: Any) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


_default_cmux_cli: cmux_cli.CmuxCli | None = None


def get_cmux_cli() -> cmux_cli.CmuxCli:
    global _default_cmux_cli
    if _default_cmux_cli is None:
        _default_cmux_cli = cmux_cli.get_cli()
    return _default_cmux_cli
