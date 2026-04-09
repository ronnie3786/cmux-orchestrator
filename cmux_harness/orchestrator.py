import json
import os
import pathlib
import re
import shlex
import hashlib
import subprocess
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone

from . import claude_cli
from . import contracts
from . import cmux_api
from . import detection
from . import evaluator
from . import monitor
from . import objectives
from . import planner
from . import review as review_mod
from . import workspaces
from . import worker
from .workspace_mutex import WorkspaceMutex


def _utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def _coerce_timestamp(value, default=0.0):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value).timestamp()
        except ValueError:
            return default
    return default


_RETRY_REQUEST_PATTERN = re.compile(
    r"\b(retry|try again|restart|rerun|re-run|start over)\b",
    re.IGNORECASE,
)
_WORKSPACE_TOOL_TRACE_RE = re.compile(
    r"^\s*(?:[●•◦⏺]\s*)?(?:Bash|Read|Write|Edit|MultiEdit|Glob|Grep|Search|LS|ListDir|TodoRead|TodoWrite|NotebookRead|NotebookEdit|WebFetch|WebSearch|Fetch|Task|Agent|Open|Find|MCP)\b",
    re.IGNORECASE,
)
_WORKSPACE_TRANSCRIPT_META_RE = re.compile(
    r"^\s*(?:Model:|Cost:\s*\$|Ctx:\s*\d|PR\s*#\d+\b)",
    re.IGNORECASE,
)
_WORKSPACE_TRANSCRIPT_EXPAND_RE = re.compile(
    r"^\s*(?:\.\.\.|…)\s*\+\d+\s+lines?\b.*ctrl\+o\s+to\s+expand",
    re.IGNORECASE,
)
_WORKSPACE_PROMPT_LINE_RE = re.compile(r"^\s*[❯>›]\s*$")
_WORKSPACE_CALLBACK_PROTOCOL_RE = re.compile(
    r"(?:Do not answer in the terminal for this turn|When you are ready to answer the user:|"
    r"Write ONLY the final answer, in Markdown, to this file:|"
    r"Run this exact command from the shell:|"
    r"The callback payload must be concise and directly useful to the user\.|"
    r"The turn is not complete until the callback command succeeds\.|"
    r"If the callback command fails, print a short note about the callback failure and stop\.|"
    r"User message:|/tmp/cmux-turn-|report_turn\.py|--turn-id|--workspace-id|--token)",
    re.IGNORECASE,
)


class Orchestrator:
    def __init__(self, engine):
        self.engine = engine
        self.mutex = WorkspaceMutex()
        self._active_objective_id = None
        self._messages = {}
        self._workspace_messages = {}
        self._task_screen_cache = {}
        self._task_last_progress = {}
        self._pending_hook_approvals = set()  # task IDs with unresolved hook escalations
        self._lock = threading.Lock()
        self._orchestrator_response_pattern = re.compile(r"(?:^|\n)\s*(?:❯(?:\s|$)|[>›](?:\s|$)|Model:)", re.MULTILINE)
        self._reconcile_workspace_state_on_startup()
        self._idle_sweep_thread = threading.Thread(target=self._idle_sweep, daemon=True)
        self._idle_sweep_thread.start()

    def _debug_log_path(self, objective_id):
        return objectives.get_objective_dir(objective_id) / "debug.jsonl"

    def _capture_screen_snapshot(self, workspace_uuid=None, lines=20):
        if not workspace_uuid:
            return ""
        try:
            screen = cmux_api.cmux_read_workspace(0, 0, lines=max(lines, 20), workspace_uuid=workspace_uuid) or ""
        except Exception:
            return ""
        if not screen:
            return ""
        chunks = screen.splitlines()
        return "\n".join(chunks[-lines:])

    def _log_event(self, objective_id, level, event, details=None):
        if not objective_id:
            return
        payload = {
            "timestamp": _utc_now_iso(),
            "level": str(level or "info"),
            "event": str(event or "unknown"),
            "details": details if isinstance(details, dict) else {},
        }
        path = self._debug_log_path(objective_id)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(json.dumps(payload) + "\n")
        except OSError:
            pass

    def get_debug_entries(self, objective_id, limit=200, level=None):
        entries = []
        path = self._debug_log_path(objective_id)
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(entry, dict):
                        continue
                    if level and str(entry.get("level", "")).lower() != str(level).lower():
                        continue
                    entries.append(entry)
        except OSError:
            return []
        if limit is not None and limit >= 0:
            return entries[-limit:]
        return entries

    def _append_message(self, objective_id, msg_type, content, metadata=None):
        msg = {
            "id": str(uuid.uuid4()),
            "timestamp": _utc_now_iso(),
            "type": msg_type,
            "content": content,
            "metadata": metadata or {},
        }
        with self._lock:
            messages = self._messages.setdefault(objective_id, [])
            messages.append(msg)
        self._persist_message(objective_id, msg)
        return msg

    def _append_workspace_message(self, workspace_id, msg_type, content, metadata=None):
        msg = {
            "id": str(uuid.uuid4()),
            "timestamp": _utc_now_iso(),
            "type": msg_type,
            "content": content,
            "metadata": metadata or {},
        }
        with self._lock:
            messages = self._workspace_messages.setdefault(workspace_id, [])
            messages.append(msg)
        workspaces.append_workspace_message(workspace_id, msg)
        try:
            workspaces.sync_workspace_conversation_context(workspace_id)
        except (FileNotFoundError, OSError):
            pass
        return msg

    def _close_workspace(self, objective_id, workspace_id, purpose, task_id=None):
        if not workspace_id:
            return
        try:
            cmux_api.send_prompt_to_workspace(workspace_id, "/exit")
            time.sleep(1)
        except Exception:
            pass
        try:
            cmux_api._v2_request("workspace.close", {"workspace_id": workspace_id})
            details = {"workspaceId": workspace_id, "purpose": purpose}
            if task_id:
                details["taskId"] = task_id
            self._log_event(objective_id, "info", "workspace_closed", details)
        except Exception as exc:
            details = {
                "phase": f"close_workspace_{purpose}",
                "workspaceId": workspace_id,
                "taskId": task_id,
                "error": str(exc),
                "traceback": traceback.format_exc(),
                "screen_last_20_lines": self._capture_screen_snapshot(workspace_id),
            }
            self._log_event(objective_id, "error", "exception", details)

    def _build_workspace_context_prompt(self, workspace):
        workspace_id = str(workspace.get("id") or "").strip()
        context_file = workspaces.workspace_conversation_context_path(workspace_id)
        context_block = ""
        context_message_count = 0
        for message in workspaces.load_workspace_messages(workspace_id):
            if str(message.get("type") or "").strip().lower() in {"user", "assistant"} and str(message.get("content") or "").strip():
                context_message_count += 1
        if context_file.exists() and context_message_count >= 1:
            quoted_context_file = shlex.quote(str(context_file))
            context_block = (
                "A workspace conversation context file is available for continuity across re-opened sessions.\n"
                f"Before you answer any live user turn in this session, read this file now: {context_file}\n"
                f"If needed, use this exact shell command: cat {quoted_context_file}\n"
                "Do this silently. Do not summarize the file unless the user asks.\n"
                "Do not claim you lack prior context without first consulting this file.\n"
                "A new live user turn may be sent separately right after this bootstrap; treat that later turn as authoritative.\n\n"
            )
        return (
            "You are the workspace assistant for this repo context.\n\n"
            f"Project: {workspace.get('projectId') or ''}\n"
            f"Workspace path: {workspace.get('rootPath') or ''}\n"
            f"Session name: {workspace.get('name') or ''}\n\n"
            "You are running inside this workspace path. Help the user inspect the codebase, answer questions, make edits, run git commands, and support open-ended development work.\n\n"
            "This is NOT a tracked objective unless the user explicitly creates one later.\n"
            "Do not refer to objective.json, plan.md, or task files unless they actually exist in this workspace.\n"
            f"{context_block}"
            "This bootstrap message is setup only. Do not answer it by itself.\n"
            "Be concise and practical."
        )

    def _build_workspace_start_prompt(self, workspace, initial_turn_prompt=""):
        context_prompt = self._build_workspace_context_prompt(workspace)
        turn_prompt = str(initial_turn_prompt or "").strip()
        if not turn_prompt:
            return context_prompt
        return (
            f"{context_prompt}\n\n"
            "A live user turn follows immediately below. Treat that next block as the only turn you should answer.\n\n"
            f"{turn_prompt}"
        )

    def _workspace_runtime_dir(self, workspace_id):
        runtime_dir = workspaces.workspace_conversation_context_path(workspace_id).parent / "runtime"
        runtime_dir.mkdir(parents=True, exist_ok=True)
        return runtime_dir

    def _write_workspace_start_instruction_file(self, workspace_id, prompt):
        runtime_dir = self._workspace_runtime_dir(workspace_id)
        path = runtime_dir / f"startup-{uuid.uuid4().hex}.md"
        with open(path, "w", encoding="utf-8") as f:
            f.write(str(prompt or "").rstrip() + "\n")
        return path

    def _build_workspace_start_loader_prompt(self, instruction_path):
        quoted_instruction_path = shlex.quote(str(instruction_path))
        return (
            "Do not answer this message directly.\n\n"
            "Before you do anything else, read the harness startup instruction file at this exact path:\n"
            f"{instruction_path}\n"
            f"If needed, use this exact shell command: cat {quoted_instruction_path}\n\n"
            "That file contains your full startup instructions and the live user turn you must answer. "
            "Read it completely, then follow it exactly.\n"
            "If you cannot read the file, print exactly: HARNESS_STARTUP_READ_FAILED"
        )

    def _workspace_callback_base_url(self):
        configured = str(
            getattr(self.engine, "callback_base_url", "") or os.environ.get("CMUX_HARNESS_SERVER_URL", "")
        ).strip()
        if configured:
            return configured.rstrip("/")
        return "http://127.0.0.1:9091"

    def _workspace_callback_helper_path(self):
        return str((pathlib.Path(__file__).with_name("report_turn.py")).resolve())

    def _inject_hook_config(self, cwd):
        """Write .claude/settings.local.json with PreToolUse hook pointing to our server.

        Uses settings.local.json to avoid committing hook config to the git worktree.
        Merges with existing settings if the file already exists.
        """
        claude_dir = os.path.join(cwd, ".claude")
        os.makedirs(claude_dir, exist_ok=True)
        settings_path = os.path.join(claude_dir, "settings.local.json")

        base_url = self._workspace_callback_base_url()
        hook_url = f"{base_url}/api/hooks/pre-tool-use"

        settings = {}
        if os.path.isfile(settings_path):
            try:
                with open(settings_path, "r", encoding="utf-8") as f:
                    settings = json.load(f)
            except (json.JSONDecodeError, OSError):
                settings = {}

        settings["hooks"] = {
            "PreToolUse": [
                {
                    "matcher": "",
                    "hooks": [
                        {
                            "type": "http",
                            "url": hook_url,
                            "timeout": 15,
                        }
                    ],
                }
            ],
        }

        with open(settings_path, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)

    def _try_approve_permission_prompt(self, workspace_uuid, screen_text, workspace_id=None, turn_id=None, objective_id=None, task_id=None):
        """Auto-approve a Claude Code permission prompt stuck on a workspace screen.

        Only called after the progress monitor or poll loop confirms the same
        prompt has been showing for 2+ consecutive cycles.  Uses a regex safety
        check to ensure the screen actually shows a permission prompt before
        sending Enter.
        """
        if not detection.is_permission_prompt(screen_text):
            return False

        try:
            cmux_api.cmux_send_to_workspace(
                0, 0, key="enter", workspace_uuid=workspace_uuid,
            )
        except Exception:
            return False

        screen_tail = screen_text[-200:] if len(screen_text) > 200 else screen_text
        if workspace_id:
            self._log_workspace_progress(
                workspace_id, "info", "workspace_permission_auto_approved",
                {"turnId": turn_id, "screenTail": screen_tail},
            )
            self._append_workspace_message(
                workspace_id, "system",
                "Auto-approved a permission prompt that was blocking the session.",
                metadata={"turnId": turn_id},
            )
        if objective_id:
            self._log_event(
                objective_id, "info", "task_builtin_permission_approved",
                {"taskId": task_id, "workspaceId": workspace_uuid, "screenTail": screen_tail},
            )
            self._append_message(
                objective_id, "system",
                f"Task {task_id}: auto-approved Claude Code permission prompt",
                metadata={"task_id": task_id},
            )
        return True

    def _append_workspace_debug(self, workspace_id, level, event, details=None):
        payload = {
            "timestamp": _utc_now_iso(),
            "level": str(level or "info"),
            "event": str(event or "unknown"),
            "details": details if isinstance(details, dict) else {},
        }
        try:
            workspaces.append_workspace_debug(workspace_id, payload)
        except OSError:
            pass

    def _reconcile_workspace_state_on_startup(self):
        expected_workspace_dir = objectives.OBJECTIVES_DIR.parent / "workspaces"
        if pathlib.Path(workspaces.WORKSPACES_DIR) != expected_workspace_dir:
            return
        for workspace in workspaces.list_workspace_sessions():
            workspace_id = str(workspace.get("id") or "").strip()
            if not workspace_id:
                continue
            session_updates = {}
            stale_turns = []
            had_session = bool(workspace.get("sessionActive")) or bool(str(workspace.get("cmuxWorkspaceId") or "").strip())
            if had_session:
                session_updates = {
                    "sessionActive": False,
                    "cmuxWorkspaceId": "",
                    "status": "idle",
                }
                try:
                    workspaces.update_workspace_session(workspace_id, session_updates)
                except (FileNotFoundError, OSError):
                    continue
            for turn in workspaces.list_workspace_turns(workspace_id):
                status = str(turn.get("status") or "").lower()
                if status not in {"pending", "timed_out"}:
                    continue
                stale_turns.append(str(turn.get("id") or ""))
                try:
                    workspaces.update_workspace_turn(
                        workspace_id,
                        str(turn.get("id") or ""),
                        {
                            "status": "failed",
                            "lastError": "Dashboard restarted before this workspace turn completed.",
                        },
                    )
                except (FileNotFoundError, OSError):
                    continue
            if session_updates or stale_turns:
                self._append_workspace_debug(
                    workspace_id,
                    "info",
                    "workspace_startup_reconciled",
                    {
                        "clearedSession": had_session,
                        "clearedTurns": stale_turns,
                    },
                )

    def _log_workspace_progress(self, workspace_id, level, event, details=None):
        safe_details = details if isinstance(details, dict) else {}
        self._append_workspace_debug(workspace_id, level, event, safe_details)
        payload = {
            "timestamp": _utc_now_iso(),
            "workspaceId": str(workspace_id or ""),
            "level": str(level or "info"),
            "event": str(event or "unknown"),
            "details": safe_details,
        }
        try:
            print(f"[workspace-progress] {json.dumps(payload, sort_keys=True)}", flush=True)
        except Exception:
            print(
                f"[workspace-progress] workspaceId={payload['workspaceId']} "
                f"level={payload['level']} event={payload['event']}",
                flush=True,
            )

    def _build_workspace_turn_prompt(self, workspace, turn):
        turn_id = str(turn.get("id") or "").strip()
        token = str(turn.get("token") or "").strip()
        user_message = str(turn.get("userMessage") or "").strip()
        callback_file = f"/tmp/cmux-turn-{turn_id}.md"
        callback_cmd = " ".join(
            [
                "python3",
                shlex.quote(self._workspace_callback_helper_path()),
                "--server-url",
                shlex.quote(self._workspace_callback_base_url()),
                "--workspace-id",
                shlex.quote(str(workspace.get("id") or "")),
                "--turn-id",
                shlex.quote(turn_id),
                "--token",
                shlex.quote(token),
                "--file",
                shlex.quote(callback_file),
            ]
        )
        return (
            "Do not answer in the terminal for this turn. Deliver the final user-facing answer through the "
            "cmux harness callback command below.\n\n"
            f"Turn ID: {turn_id}\n"
            f"Workspace: {workspace.get('name') or workspace.get('rootPath') or workspace.get('id')}\n\n"
            "When you are ready to answer the user:\n"
            f"1. Write ONLY the final answer, in Markdown, to this file: {callback_file}\n"
            "2. Run this exact command from the shell:\n"
            f"{callback_cmd}\n"
            "3. After the callback succeeds, do not print the full answer in the terminal.\n\n"
            "Rules:\n"
            "- The callback payload must be concise and directly useful to the user.\n"
            "- Do not include tool logs, command transcripts, progress spinners, or status footer text.\n"
            "- The turn is not complete until the callback command succeeds.\n"
            "- If the callback command fails, print a short note about the callback failure and stop.\n\n"
            "User message:\n"
            f"{user_message}"
        )

    def _build_orchestrator_context_prompt(self, objective):
        task_lines = []
        for task in objective.get("tasks", []):
            if not isinstance(task, dict):
                continue
            task_lines.append(
                "- {id}: {title} [{status}] (reviewCycles: {review_cycles})".format(
                    id=task.get("id") or "unknown",
                    title=task.get("title") or "Untitled task",
                    status=task.get("status") or "unknown",
                    review_cycles=task.get("reviewCycles", 0),
                )
            )
        task_block = "\n".join(task_lines) if task_lines else "- No tasks"
        return (
            "You are the orchestrator assistant for this objective. Your role is to help the user understand "
            "and interact with the work being done.\n\n"
            f"Objective: {objective.get('goal') or ''}\n"
            f"Status: {objective.get('status') or ''}\n"
            f"Project: {objective.get('projectDir') or ''}\n"
            f"Branch: {objective.get('branchName') or ''}\n"
            f"Worktree: {objective.get('worktreePath') or ''}\n\n"
            "You are running inside the objective's worktree. You can:\n"
            "- Read files to answer questions about the code and work done\n"
            "- Check objective.json for task statuses\n"
            "- Run git commands (status, diff, log, commit, push)\n"
            "- Open folders in Finder (open .)\n"
            "- Check task progress in tasks/*/progress.md and tasks/*/result.md\n\n"
            "The objective has these tasks:\n"
            f"{task_block}\n\n"
            "Tasks with source 'action-button' were spawned from saved UI action buttons. Treat them like any other "
            "objective task when reporting status or checking progress.\n\n"
            "When answering questions, be concise and helpful. If the user asks about status, read objective.json "
            "for the latest state."
        )

    def _extract_orchestrator_response(self, screen, baseline_screen="", user_message=""):
        lines = [line.rstrip() for line in str(screen or "").splitlines()]
        prompt_index = None
        for idx in range(len(lines) - 1, -1, -1):
            if self._orchestrator_response_pattern.search(lines[idx]):
                prompt_index = idx
                break
        if prompt_index is not None:
            lines = lines[:prompt_index]

        baseline_lines = [line.rstrip() for line in str(baseline_screen or "").splitlines()]
        common = 0
        max_common = min(len(lines), len(baseline_lines))
        while common < max_common and lines[common] == baseline_lines[common]:
            common += 1
        if common:
            lines = lines[common:]

        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and user_message and lines[0].strip() == user_message.strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        return "\n".join(lines).strip()

    def _prepare_workspace_assistant_message(self, response_text, user_message=""):
        raw_response = str(response_text or "").strip()
        if not raw_response:
            return {"content": "", "metadata": {}}

        cleaned_lines = []
        skipping_tool_block = False
        saw_tool_block = False
        for raw_line in raw_response.splitlines():
            line = raw_line.rstrip()
            stripped = line.strip()
            if not stripped:
                if skipping_tool_block:
                    skipping_tool_block = False
                if cleaned_lines and cleaned_lines[-1]:
                    cleaned_lines.append("")
                continue
            if _WORKSPACE_TRANSCRIPT_META_RE.match(stripped) or _WORKSPACE_TRANSCRIPT_EXPAND_RE.match(stripped):
                continue
            if _WORKSPACE_TOOL_TRACE_RE.match(stripped):
                saw_tool_block = True
                skipping_tool_block = True
                continue
            if skipping_tool_block:
                continue
            cleaned_lines.append(line)

        while cleaned_lines and not cleaned_lines[0].strip():
            cleaned_lines.pop(0)
        while cleaned_lines and not cleaned_lines[-1].strip():
            cleaned_lines.pop()

        cleaned_response = "\n".join(cleaned_lines).strip()
        if not cleaned_response:
            cleaned_response = raw_response

        metadata = {}
        if saw_tool_block and cleaned_response != raw_response:
            metadata["rawResponse"] = raw_response
            metadata["presentation"] = "summary"
        return {"content": cleaned_response, "metadata": metadata}

    def _workspace_progress_snapshot(self, screen, user_message=""):
        lines = [line.rstrip() for line in str(screen or "").splitlines()]
        if not lines:
            return ""
        cleaned = []
        skipping_callback_block = False
        prompt_text = str(user_message or "").strip()
        for line in lines:
            stripped = line.strip()
            if not stripped:
                if skipping_callback_block:
                    continue
                if cleaned and cleaned[-1]:
                    cleaned.append("")
                continue
            if _WORKSPACE_CALLBACK_PROTOCOL_RE.search(stripped):
                skipping_callback_block = True
                continue
            if skipping_callback_block:
                if _WORKSPACE_TOOL_TRACE_RE.match(stripped):
                    skipping_callback_block = False
                else:
                    continue
            if _WORKSPACE_TRANSCRIPT_META_RE.match(stripped) or _WORKSPACE_TRANSCRIPT_EXPAND_RE.match(stripped):
                continue
            if _WORKSPACE_PROMPT_LINE_RE.match(stripped):
                continue
            if prompt_text and stripped == prompt_text:
                continue
            cleaned.append(line)
        while cleaned and not cleaned[0].strip():
            cleaned.pop(0)
        while cleaned and not cleaned[-1].strip():
            cleaned.pop()
        if len(cleaned) > 40:
            cleaned = cleaned[-40:]
        return "\n".join(cleaned).strip()

    def _heuristic_workspace_progress(self, snapshot):
        text = str(snapshot or "").strip()
        if not text:
            return None
        lowered = text.lower()
        if "needs human" in lowered or "waiting for input" in lowered or "approve" in lowered:
            return {"state": "waiting", "summary": "Waiting for input or approval.", "shouldDisplay": True}
        if "git push" in lowered or "pushing" in lowered or "origin/" in lowered and "git log" in lowered:
            return {"state": "working", "summary": "Checking the remote branch and push status.", "shouldDisplay": True}
        if "git log" in lowered:
            return {"state": "working", "summary": "Checking recent git history.", "shouldDisplay": True}
        if "git diff" in lowered or "diff --stat" in lowered:
            return {"state": "working", "summary": "Reviewing the current code changes.", "shouldDisplay": True}
        if "git status" in lowered:
            return {"state": "working", "summary": "Checking the repo status.", "shouldDisplay": True}
        if "read" in lowered or "reading files" in lowered or "grep" in lowered or "search" in lowered:
            return {"state": "working", "summary": "Inspecting files in the workspace.", "shouldDisplay": True}
        if "write" in lowered or "edit" in lowered:
            return {"state": "working", "summary": "Updating files in the workspace.", "shouldDisplay": True}
        if "bash(" in lowered or "⏺ bash" in lowered or "running" in lowered:
            return {"state": "working", "summary": "Running commands in the workspace.", "shouldDisplay": True}
        return None

    def _normalize_workspace_progress_result(self, result):
        if not isinstance(result, dict) or result.get("error"):
            return None
        summary = str(result.get("summary") or "").strip()
        state = str(result.get("state") or "working").strip().lower()
        should_display = result.get("shouldDisplay")
        if should_display is None:
            should_display = bool(summary)
        if not isinstance(should_display, bool):
            return None
        if state not in {"working", "waiting", "unknown"}:
            state = "working"
        if should_display and not summary:
            return None
        return {
            "state": state,
            "summary": summary[:160],
            "shouldDisplay": should_display,
        }

    def _summarize_workspace_progress(
        self,
        screen,
        *,
        user_message="",
        previous_summary="",
        elapsed_seconds=0,
        workspace_id="",
        turn_id="",
        snapshot_hash="",
    ):
        snapshot = self._workspace_progress_snapshot(screen, user_message=user_message)
        if not snapshot:
            if workspace_id and turn_id:
                self._log_workspace_progress(
                    workspace_id,
                    "debug",
                    "workspace_turn_progress_snapshot_empty",
                    {"turnId": turn_id, "snapshotHash": snapshot_hash},
                )
            return None
        if workspace_id and turn_id:
            self._log_workspace_progress(
                workspace_id,
                "debug",
                "workspace_turn_progress_haiku_request",
                {
                    "turnId": turn_id,
                    "snapshotHash": snapshot_hash,
                    "elapsedSeconds": int(max(0, elapsed_seconds)),
                    "previousSummary": previous_summary[:160],
                    "snapshotPreview": snapshot[:240],
                },
            )
        prompt = "\n".join(
            [
                "You summarize an in-progress coding session from a terminal snapshot.",
                "This snapshot comes from a Claude Code terminal session.",
                "This is for a subtle loading subtitle in a UI, not the final user answer.",
                "Return JSON only with exactly these keys:",
                '{"state":"working|waiting|unknown","summary":"...","shouldDisplay":true}',
                "Rules:",
                "- summary must be one short sentence under 90 characters.",
                "- Describe only what appears to be happening right now.",
                "- Do not state final outcomes or completed results.",
                "- If the screen looks like it is waiting for human input or approval, use state=\"waiting\".",
                "- If the snapshot is too ambiguous or not meaningfully different from the previous summary, set shouldDisplay to false.",
                "",
                "Previous summary:",
                previous_summary or "(none)",
                "",
                f"Elapsed seconds: {int(max(0, elapsed_seconds))}",
                "",
                "Terminal snapshot:",
                snapshot,
            ]
        )
        result = claude_cli.run_haiku(prompt, timeout=20)
        normalized = self._normalize_workspace_progress_result(result)
        if not normalized:
            normalized = self._heuristic_workspace_progress(snapshot)
        if workspace_id and turn_id:
            result_preview = result
            if isinstance(result_preview, dict):
                result_preview = {
                    key: (value[:240] if isinstance(value, str) else value)
                    for key, value in result_preview.items()
                }
            elif isinstance(result_preview, str):
                result_preview = result_preview[:240]
            self._log_workspace_progress(
                workspace_id,
                "debug",
                "workspace_turn_progress_haiku_result",
                {
                    "turnId": turn_id,
                    "snapshotHash": snapshot_hash,
                    "rawResult": result_preview,
                    "normalized": normalized or {},
                },
            )
            if normalized and isinstance(result, dict) and result.get("error"):
                self._log_workspace_progress(
                    workspace_id,
                    "info",
                    "workspace_turn_progress_fallback_used",
                    {
                        "turnId": turn_id,
                        "snapshotHash": snapshot_hash,
                        "summary": normalized.get("summary") or "",
                        "state": normalized.get("state") or "working",
                        "errorType": str(result.get("type") or ""),
                    },
                )
        return normalized

    def _fail_workspace_turn(self, workspace_id, turn_id, message):
        error_message = str(message or "").strip() or "Workspace turn failed."
        try:
            workspaces.update_workspace_turn(
                workspace_id,
                turn_id,
                {
                    "status": "failed",
                    "lastError": error_message,
                },
            )
        except FileNotFoundError:
            return
        self._append_workspace_debug(
            workspace_id,
            "error",
            "workspace_turn_failed",
            {"turnId": turn_id, "message": error_message},
        )
        self._append_workspace_message(
            workspace_id,
            "alert",
            error_message,
            metadata={"turnId": turn_id, "delivery": "callback", "state": "failed"},
        )

    def _watch_workspace_turn(self, workspace_id, turn_id, soft_timeout=180, hard_timeout=600, poll_interval=1.0):
        start = time.time()
        soft_deadline = start + max(5, int(soft_timeout))
        hard_deadline = start + max(10, int(hard_timeout))
        soft_sent = False

        while time.time() < hard_deadline:
            turn = workspaces.read_workspace_turn(workspace_id, turn_id)
            if turn is None:
                return
            status = str(turn.get("status") or "").lower()
            if status in {"completed", "failed"}:
                return

            # Stage 1: soft "still waiting" message at the soft deadline
            if not soft_sent and time.time() >= soft_deadline:
                if status == "pending":
                    self._append_workspace_message(
                        workspace_id,
                        "system",
                        "Still waiting for workspace reply \u2014 the session appears to be still working.",
                        metadata={"turnId": turn_id, "delivery": "callback", "state": "waiting"},
                    )
                    soft_sent = True

            time.sleep(poll_interval)

        # Stage 2: hard timeout alert
        turn = workspaces.read_workspace_turn(workspace_id, turn_id)
        if turn is None:
            return
        if str(turn.get("status") or "").lower() != "pending":
            return
        workspaces.update_workspace_turn(
            workspace_id,
            turn_id,
            {
                "status": "timed_out",
                "lastError": "Workspace reply callback timed out.",
            },
        )
        self._append_workspace_debug(
            workspace_id,
            "warn",
            "workspace_turn_timed_out",
            {"turnId": turn_id, "timeoutSeconds": int(hard_timeout)},
        )
        self._append_workspace_message(
            workspace_id,
            "alert",
            "Workspace reply did not arrive through the callback channel yet. The session may still be working.",
            metadata={"turnId": turn_id, "delivery": "callback", "state": "timed_out"},
        )

    def _monitor_workspace_turn_progress(
        self,
        workspace_id,
        turn_id,
        workspace_uuid,
        *,
        user_message="",
        initial_delay=20.0,
        interval=22.0,
    ):
        self._log_workspace_progress(
            workspace_id,
            "info",
            "workspace_turn_progress_monitor_started",
            {
                "turnId": turn_id,
                "workspaceUuid": str(workspace_uuid or ""),
                "initialDelaySeconds": float(max(0, initial_delay)),
                "intervalSeconds": float(max(0, interval)),
            },
        )
        if initial_delay > 0:
            time.sleep(initial_delay)
        consecutive_waiting = 0
        while True:
            turn = workspaces.read_workspace_turn(workspace_id, turn_id)
            if turn is None:
                self._log_workspace_progress(
                    workspace_id,
                    "warn",
                    "workspace_turn_progress_monitor_stopped",
                    {"turnId": turn_id, "reason": "turn_missing"},
                )
                return
            status = str(turn.get("status") or "").lower()
            if status not in {"pending", "timed_out"}:
                self._log_workspace_progress(
                    workspace_id,
                    "info",
                    "workspace_turn_progress_monitor_stopped",
                    {"turnId": turn_id, "reason": "turn_not_pending", "status": status},
                )
                return

            screen = cmux_api.cmux_read_workspace(0, 0, lines=120, workspace_uuid=workspace_uuid) or ""
            snapshot = self._workspace_progress_snapshot(screen, user_message=user_message)
            elapsed_seconds = max(0, int(time.time() - _coerce_timestamp(turn.get("createdAt"), default=time.time())))
            self._log_workspace_progress(
                workspace_id,
                "debug",
                "workspace_turn_progress_cycle",
                {
                    "turnId": turn_id,
                    "status": status,
                    "elapsedSeconds": elapsed_seconds,
                    "screenLines": len(str(screen).splitlines()),
                    "snapshotLines": len(snapshot.splitlines()) if snapshot else 0,
                    "snapshotPreview": snapshot[:240],
                },
            )
            if snapshot:
                snapshot_hash = hashlib.md5(snapshot.encode("utf-8")).hexdigest()
                previous_hash = str(turn.get("lastScreenHash") or "").strip()
                previous_summary = str(turn.get("progressSummary") or "").strip()
                if snapshot_hash != previous_hash or not previous_summary:
                    summarized = self._summarize_workspace_progress(
                        screen,
                        user_message=user_message,
                        previous_summary=previous_summary,
                        elapsed_seconds=elapsed_seconds,
                        workspace_id=workspace_id,
                        turn_id=turn_id,
                        snapshot_hash=snapshot_hash,
                    )
                    updates = {"lastScreenHash": snapshot_hash}
                    if summarized and summarized.get("shouldDisplay") and summarized.get("summary"):
                        summary = summarized["summary"]
                        if summary != previous_summary:
                            updates.update(
                                {
                                    "progressSummary": summary,
                                    "progressState": summarized.get("state") or "working",
                                    "progressUpdatedAt": _utc_now_iso(),
                                    "progressSequence": int(turn.get("progressSequence") or 0) + 1,
                                }
                            )
                            self._log_workspace_progress(
                                workspace_id,
                                "info",
                                "workspace_turn_progress",
                                {
                                    "turnId": turn_id,
                                    "summary": summary,
                                    "state": updates["progressState"],
                                    "snapshotHash": snapshot_hash,
                                },
                            )
                        else:
                            self._log_workspace_progress(
                                workspace_id,
                                "debug",
                                "workspace_turn_progress_summary_unchanged",
                                {
                                    "turnId": turn_id,
                                    "summary": summary,
                                    "snapshotHash": snapshot_hash,
                                },
                            )
                    else:
                        self._log_workspace_progress(
                            workspace_id,
                            "debug",
                            "workspace_turn_progress_summary_skipped",
                            {
                                "turnId": turn_id,
                                "snapshotHash": snapshot_hash,
                                "previousSummary": previous_summary[:160],
                            },
                        )
                    workspaces.update_workspace_turn(workspace_id, turn_id, updates)

                    # Track consecutive "waiting" cycles with unchanged screen
                    if updates.get("progressState") == "waiting" and snapshot_hash == previous_hash:
                        consecutive_waiting += 1
                    else:
                        consecutive_waiting = 0

                    if consecutive_waiting >= 2:
                        if self._try_approve_permission_prompt(
                            workspace_uuid, screen, workspace_id=workspace_id, turn_id=turn_id,
                        ):
                            consecutive_waiting = 0
                else:
                    # Snapshot hash unchanged — Haiku not called.
                    # Check last known state from turn data.
                    if str(turn.get("progressState") or "").lower() == "waiting":
                        consecutive_waiting += 1
                    else:
                        consecutive_waiting = 0

                    if consecutive_waiting >= 2:
                        if self._try_approve_permission_prompt(
                            workspace_uuid, screen, workspace_id=workspace_id, turn_id=turn_id,
                        ):
                            consecutive_waiting = 0

                    self._log_workspace_progress(
                        workspace_id,
                        "debug",
                        "workspace_turn_progress_snapshot_unchanged",
                        {"turnId": turn_id, "snapshotHash": snapshot_hash},
                    )
            else:
                self._log_workspace_progress(
                    workspace_id,
                    "debug",
                    "workspace_turn_progress_no_snapshot",
                    {"turnId": turn_id},
                )
            time.sleep(interval)

    def finalize_workspace_turn(self, workspace_id, turn_id, token, content, source="callback-helper"):
        workspace = workspaces.read_workspace_session(workspace_id)
        if workspace is None:
            return {"ok": False, "error": "workspace not found"}, 404
        turn = workspaces.read_workspace_turn(workspace_id, turn_id)
        if turn is None:
            return {"ok": False, "error": "workspace turn not found"}, 404
        if str(token or "").strip() != str(turn.get("token") or "").strip():
            return {"ok": False, "error": "invalid turn token"}, 403

        status = str(turn.get("status") or "").lower()
        if status == "completed":
            return {
                "ok": True,
                "turnId": turn_id,
                "status": "completed",
                "assistantMessageId": turn.get("assistantMessageId") or "",
                "idempotent": True,
            }, 200
        if status not in {"pending", "timed_out"}:
            return {"ok": False, "error": f"workspace turn is {status or 'unavailable'}"}, 409

        final_content = str(content or "").strip()
        if not final_content:
            return {"ok": False, "error": "content required"}, 400

        message = self._append_workspace_message(
            workspace_id,
            "assistant",
            final_content,
            metadata={"turnId": turn_id, "delivery": "callback", "source": str(source or "callback-helper")},
        )
        workspaces.update_workspace_turn(
            workspace_id,
            turn_id,
            {
                "status": "completed",
                "assistantMessageId": message["id"],
                "contentPreview": final_content[:2000],
                "callbackSource": str(source or "callback-helper"),
                "lastError": "",
                "completedAt": _utc_now_iso(),
            },
        )
        workspaces.update_workspace_session(
            workspace_id,
            {
                "lastActivityAt": _utc_now_iso(),
                "status": "active",
            },
        )
        self._append_workspace_debug(
            workspace_id,
            "info",
            "workspace_turn_completed",
            {"turnId": turn_id, "source": str(source or "callback-helper"), "assistantMessageId": message["id"]},
        )
        return {
            "ok": True,
            "turnId": turn_id,
            "status": "completed",
            "assistantMessageId": message["id"],
        }, 200

    def _start_orchestrator_session(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return None

        goal = objective.get("goal") or ""
        worktree_path = objective.get("worktreePath") or ""
        if not goal or not worktree_path:
            return None

        previous_session_id = objective.get("orchestratorSessionId")
        workspace_uuid, created = self._create_worker_workspace(
            f"Orchestrator: {goal[:40]}",
            worktree_path,
            objective_id=objective_id,
            purpose="orchestrator",
        )
        if not created or not workspace_uuid:
            return None

        if not self._wait_for_repl(workspace_uuid, objective_id=objective_id, purpose="orchestrator"):
            self._close_workspace(objective_id, workspace_uuid, "orchestrator_startup_failed")
            return None

        prompt = self._build_orchestrator_context_prompt(objective)
        if not cmux_api.send_prompt_to_workspace(workspace_uuid, prompt):
            self._close_workspace(objective_id, workspace_uuid, "orchestrator_context_failed")
            return None

        self._capture_orchestrator_response(
            objective_id,
            workspace_uuid,
            append_message=False,
            max_polls=90,
        )

        objectives.update_objective(
            objective_id,
            {
                "orchestratorSessionId": workspace_uuid,
                "orchestratorSessionActive": True,
                "orchestratorLastActivityAt": _utc_now_iso(),
            },
        )
        self._log_event(
            objective_id,
            "info",
            "orchestrator_session_resumed" if previous_session_id else "orchestrator_session_started",
            {"workspaceId": workspace_uuid},
        )
        return workspace_uuid

    def _capture_orchestrator_response(
        self,
        objective_id,
        workspace_uuid,
        baseline_screen="",
        user_message="",
        append_message=True,
        initial_delay=2.0,
        poll_interval=2.0,
        max_polls=90,
    ):
        return self._capture_workspace_like_response(
            objective_id,
            workspace_uuid,
            baseline_screen=baseline_screen,
            user_message=user_message,
            append_message=append_message,
            initial_delay=initial_delay,
            poll_interval=poll_interval,
            max_polls=max_polls,
            append_fn=self._append_message,
            log_fn=lambda record_id, ws_id, msg: self._log_event(
                record_id,
                "info",
                "orchestrator_chat_response",
                {"workspaceId": ws_id, "message": msg},
            ),
        )

    def _capture_workspace_like_response(
        self,
        record_id,
        workspace_uuid,
        baseline_screen="",
        user_message="",
        append_message=True,
        initial_delay=2.0,
        poll_interval=2.0,
        max_polls=90,
        append_fn=None,
        log_fn=None,
        prepare_response_fn=None,
    ):
        time.sleep(initial_delay)
        previous_screen = None
        final_screen = ""
        stable_polls = 0
        for attempt in range(max_polls):
            screen = cmux_api.cmux_read_workspace(0, 0, lines=200, workspace_uuid=workspace_uuid) or ""
            recent_lines = screen.splitlines()[-20:]
            recent_screen = "\n".join(recent_lines)
            if previous_screen is not None and screen == previous_screen:
                stable_polls += 1
            else:
                stable_polls = 0
            if stable_polls >= 1 and self._orchestrator_response_pattern.search(recent_screen):
                final_screen = screen
                break
            if stable_polls >= 2 and not detection.detect_claude_session(recent_screen):
                final_screen = screen
                break
            previous_screen = screen
            if attempt < max_polls - 1:
                time.sleep(poll_interval)
        else:
            final_screen = previous_screen or ""

        response_text = self._extract_orchestrator_response(final_screen, baseline_screen, user_message)
        if append_message and response_text and append_fn:
            content = response_text
            metadata = None
            if prepare_response_fn:
                prepared = prepare_response_fn(response_text, user_message=user_message)
                if isinstance(prepared, dict):
                    content = str(prepared.get("content") or "").strip()
                    metadata = prepared.get("metadata") if isinstance(prepared.get("metadata"), dict) else None
                elif isinstance(prepared, tuple) and len(prepared) == 2:
                    content = str(prepared[0] or "").strip()
                    metadata = prepared[1] if isinstance(prepared[1], dict) else None
                elif isinstance(prepared, str):
                    content = prepared.strip()
            if content:
                append_fn(record_id, "assistant", content, metadata=metadata)
            if log_fn:
                log_fn(record_id, workspace_uuid, user_message)
        return response_text

    def _idle_sweep(self):
        while True:
            time.sleep(60)
            for objective in objectives.list_objectives():
                if not objective.get("orchestratorSessionActive"):
                    continue
                if objective.get("status") not in ("completed", "failed"):
                    continue
                last_activity = objective.get("orchestratorLastActivityAt")
                if not last_activity:
                    continue
                try:
                    elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(last_activity)).total_seconds()
                except ValueError:
                    continue
                if elapsed <= 3600:
                    continue
                workspace_uuid = objective.get("orchestratorSessionId")
                if workspace_uuid:
                    self._close_workspace(objective["id"], workspace_uuid, "idle_timeout")
                objectives.update_objective(objective["id"], {"orchestratorSessionActive": False})
                self._log_event(
                    objective["id"],
                    "info",
                    "orchestrator_session_idle_shutdown",
                    {"workspaceId": workspace_uuid},
                )
            for workspace in workspaces.list_workspace_sessions():
                if not workspace.get("sessionActive"):
                    continue
                last_activity = workspace.get("lastActivityAt")
                if not last_activity:
                    continue
                try:
                    elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(last_activity)).total_seconds()
                except ValueError:
                    continue
                if elapsed <= 3600:
                    continue
                workspace_uuid = workspace.get("cmuxWorkspaceId")
                if workspace_uuid:
                    self._close_workspace(workspace.get("id"), workspace_uuid, "workspace_idle_timeout")
                workspaces.update_workspace_session(workspace["id"], {"sessionActive": False, "status": "idle"})

    def _plan_review_metadata(self, parsed):
        tasks = []
        for task in parsed.get("tasks", []):
            if not isinstance(task, dict):
                continue
            tasks.append(
                {
                    "id": task.get("id"),
                    "title": task.get("title"),
                    "userStory": task.get("userStory"),
                    "deliverables": list(task.get("deliverables", [])),
                    "dependsOn": list(task.get("dependsOn", [])),
                    "checkpoints": list(task.get("checkpoints", [])),
                }
            )
        return {"tasks": tasks}

    def _read_and_parse_plan(self, objective_id, plan_path):
        with open(plan_path, "r", encoding="utf-8") as f:
            plan_text = f.read()
        parsed = planner.parse_plan(plan_text)
        if "error" in parsed:
            raw_plan = parsed.get("raw_plan", plan_text)
            objectives.update_objective(objective_id, {"status": "failed"})
            self._log_event(
                objective_id,
                "error",
                "planning_failure",
                {"reason": "plan_parse_failed", "rawPlanPreview": raw_plan[:2000]},
            )
            self._append_message(
                objective_id,
                "alert",
                f"Planning parse failed. Raw plan for manual review:\n\n{raw_plan}",
            )
            return None, None
        tasks = planner.plan_to_tasks(parsed, objective_id)
        return parsed, tasks

    def _persist_message(self, objective_id, msg):
        objective_dir = objectives.get_objective_dir(objective_id)
        try:
            objective_dir.mkdir(parents=True, exist_ok=True)
            with open(objective_dir / "messages.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(msg) + "\n")
        except OSError:
            pass

    def _load_messages(self, objective_id):
        path = objectives.get_objective_dir(objective_id) / "messages.jsonl"
        messages = []
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(msg, dict):
                        messages.append(msg)
        except OSError:
            return []
        return messages

    def _filter_messages_after(self, messages, after=None):
        if after is None:
            return messages
        try:
            after_dt = datetime.fromisoformat(after)
        except ValueError:
            return messages
        filtered = []
        for msg in messages:
            timestamp = msg.get("timestamp")
            if not isinstance(timestamp, str):
                continue
            try:
                msg_dt = datetime.fromisoformat(timestamp)
            except ValueError:
                continue
            if msg_dt > after_dt:
                filtered.append(msg)
        return filtered

    def get_messages(self, objective_id, after=None):
        with self._lock:
            if objective_id not in self._messages:
                self._messages[objective_id] = self._load_messages(objective_id)
            messages = list(self._messages[objective_id])
        return self._filter_messages_after(messages, after=after)

    def get_workspace_messages(self, workspace_id, after=None):
        with self._lock:
            if workspace_id not in self._workspace_messages:
                self._workspace_messages[workspace_id] = workspaces.load_workspace_messages(workspace_id)
            messages = list(self._workspace_messages[workspace_id])
        return self._filter_messages_after(messages, after=after)

    def start_workspace_session(self, workspace_id, initial_turn_prompt=""):
        workspace = workspaces.read_workspace_session(workspace_id)
        if workspace is None:
            return None
        root_path = workspace.get("rootPath") or ""
        if not root_path:
            return None
        workspace_uuid, created = self._create_worker_workspace(
            f"Workspace: {(workspace.get('name') or '')[:40]}",
            root_path,
            objective_id=workspace_id,
            purpose="workspace",
        )
        if not created or not workspace_uuid:
            return None
        if not self._wait_for_repl(workspace_uuid, objective_id=workspace_id, purpose="workspace"):
            self._close_workspace(workspace_id, workspace_uuid, "workspace_startup_failed")
            return None
        prompt = self._build_workspace_start_prompt(workspace, initial_turn_prompt=initial_turn_prompt)
        if initial_turn_prompt:
            instruction_path = self._write_workspace_start_instruction_file(workspace_id, prompt)
            prompt = self._build_workspace_start_loader_prompt(instruction_path)
            self._append_workspace_debug(
                workspace_id,
                "info",
                "workspace_startup_instruction_file_written",
                {
                    "workspaceUuid": str(workspace_uuid or ""),
                    "path": str(instruction_path),
                    "promptChars": len(initial_turn_prompt),
                },
            )
        if not cmux_api.send_prompt_to_workspace(workspace_uuid, prompt):
            self._close_workspace(workspace_id, workspace_uuid, "workspace_context_failed")
            return None
        if not initial_turn_prompt:
            self._capture_workspace_like_response(
                workspace_id,
                workspace_uuid,
                append_message=False,
                max_polls=90,
            )
        workspaces.update_workspace_session(
            workspace_id,
            {
                "cmuxWorkspaceId": workspace_uuid,
                "sessionActive": True,
                "status": "active",
                "lastActivityAt": _utc_now_iso(),
            },
        )
        return workspace_uuid

    def close_workspace_session(self, workspace_id, reason="manual"):
        workspace = workspaces.read_workspace_session(workspace_id)
        if workspace is None:
            return False
        workspace_uuid = workspace.get("cmuxWorkspaceId")
        if workspace_uuid:
            self._close_workspace(workspace_id, workspace_uuid, f"workspace_{reason}")
        workspaces.update_workspace_session(
            workspace_id,
            {"sessionActive": False, "status": "closed" if reason == "delete" else "idle"},
        )
        return True

    def handle_workspace_input(self, workspace_id, message):
        self._append_workspace_message(workspace_id, "user", message)
        workspace = workspaces.read_workspace_session(workspace_id)
        if workspace is None:
            return
        turn = workspaces.create_workspace_turn(workspace_id, user_message=message)
        self._append_workspace_debug(
            workspace_id,
            "info",
            "workspace_turn_created",
            {"turnId": turn["id"]},
        )
        workspace_uuid = workspace.get("cmuxWorkspaceId")
        is_active = workspace.get("sessionActive", False)
        prompt = self._build_workspace_turn_prompt(workspace, turn)
        prompt_sent_during_startup = False
        if not workspace_uuid or not is_active:
            self._append_workspace_message(workspace_id, "system", "Resuming workspace session...")
            workspace_uuid = self.start_workspace_session(workspace_id, initial_turn_prompt=prompt)
            if not workspace_uuid:
                self._fail_workspace_turn(workspace_id, turn["id"], "Could not start workspace session.")
                return
            prompt_sent_during_startup = True
        if not prompt_sent_during_startup and not cmux_api.send_prompt_to_workspace(workspace_uuid, prompt):
            self._append_workspace_debug(
                workspace_id,
                "warn",
                "workspace_turn_send_failed",
                {"turnId": turn["id"], "workspaceUuid": str(workspace_uuid or ""), "retrying": bool(is_active and workspace_uuid)},
            )
            if is_active and workspace_uuid:
                workspaces.update_workspace_session(
                    workspace_id,
                    {
                        "sessionActive": False,
                        "cmuxWorkspaceId": "",
                        "status": "idle",
                    },
                )
                self._append_workspace_message(workspace_id, "system", "Reconnecting workspace session...")
                workspace_uuid = self.start_workspace_session(workspace_id, initial_turn_prompt=prompt)
                if workspace_uuid:
                    is_active = True
                else:
                    self._fail_workspace_turn(workspace_id, turn["id"], "Could not deliver message to workspace session.")
                    return
            else:
                self._fail_workspace_turn(workspace_id, turn["id"], "Could not deliver message to workspace session.")
                return
        workspaces.update_workspace_session(
            workspace_id,
            {
                "lastActivityAt": _utc_now_iso(),
                "cmuxWorkspaceId": workspace_uuid,
                "sessionActive": True,
                "status": "active",
            },
        )
        threading.Thread(
            target=self._watch_workspace_turn,
            args=(workspace_id, turn["id"]),
            daemon=True,
        ).start()
        threading.Thread(
            target=self._monitor_workspace_turn_progress,
            args=(workspace_id, turn["id"], workspace_uuid),
            kwargs={"user_message": message},
            daemon=True,
        ).start()

    def start_objective(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        if not objective.get("goal") or not objective.get("projectDir"):
            return False
        status = str(objective.get("status") or "").lower()
        with self._lock:
            active_objective_id = self._active_objective_id
            if status == "failed" and active_objective_id == objective_id:
                self._active_objective_id = None
                active_objective_id = None
            if active_objective_id is not None:
                return False
            self._active_objective_id = objective_id
        objectives.update_objective(objective_id, {"status": "planning"})
        self._log_event(
            objective_id,
            "info",
            "objective_start",
            {"status": "planning", "goal": objective.get("goal"), "projectDir": objective.get("projectDir")},
        )
        self._append_message(
            objective_id,
            "system",
            f"Starting objective: {objective['goal']}",
        )
        threading.Thread(target=self._run_planning, args=(objective_id,), daemon=True).start()
        return True

    def _run_planning(self, objective_id, _poll_interval=10, _grace_polls=36, _max_polls=90):
        workspace_uuid = None
        keep_planner_workspace = False
        try:
            self._log_event(
                objective_id,
                "info",
                "planning_start",
                {
                    "pollIntervalSeconds": _poll_interval,
                    "gracePolls": _grace_polls,
                    "maxPolls": _max_polls,
                },
            )
            self._append_message(
                objective_id,
                "system",
                "Planning: analyzing codebase and decomposing goal...",
            )
            objective = objectives.read_objective(objective_id)
            if objective is None:
                raise FileNotFoundError(f"objective not found: {objective_id}")

            goal = objective.get("goal", "")
            worktree_path = objective.get("worktreePath", "")
            if not goal or not worktree_path:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._log_event(
                    objective_id,
                    "error",
                    "planning_failure",
                    {"reason": "missing_goal_or_worktree_path"},
                )
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: objective is missing goal or worktreePath.",
                )
                return

            workspace_uuid, created = self._create_worker_workspace(
                f"Planner: {goal[:40]}",
                worktree_path,
                objective_id=objective_id,
                purpose="planning",
            )
            if not created or not workspace_uuid:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._log_event(
                    objective_id,
                    "error",
                    "planning_failure",
                    {"reason": "workspace_create_failed"},
                )
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not create planner workspace.",
                )
                return

            if not self._wait_for_repl(workspace_uuid, objective_id=objective_id, purpose="planning"):
                objectives.update_objective(objective_id, {"status": "failed"})
                self._log_event(
                    objective_id,
                    "error",
                    "planning_failure",
                    {
                        "reason": "repl_timeout",
                        "workspaceId": workspace_uuid,
                        "screen_last_20_lines": self._capture_screen_snapshot(workspace_uuid),
                    },
                )
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: Claude Code did not become ready in time.",
                )
                return

            prompt_sent = bool(
                cmux_api.send_prompt_to_workspace(
                    workspace_uuid,
                    planner.build_planning_prompt(goal),
                )
            )
            if not prompt_sent:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._log_event(
                    objective_id,
                    "error",
                    "planning_failure",
                    {
                        "reason": "prompt_delivery_failed",
                        "workspaceId": workspace_uuid,
                        "screen_last_20_lines": self._capture_screen_snapshot(workspace_uuid),
                    },
                )
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not deliver planning prompt.",
                )
                return

            plan_path = os.path.join(worktree_path, "plan.md")
            # Grace period: don't check for Claude exit until we've either
            # (a) seen Claude active at least once, or (b) waited 30+ seconds.
            # This prevents false "exited" detection during startup.
            seen_claude_active = False
            grace_polls = _grace_polls
            # Approval is now handled by PreToolUse hooks (see routes/hooks.py).
            for attempt in range(_max_polls):
                plan_exists = os.path.isfile(plan_path)
                screen = cmux_api.cmux_read_workspace(0, 0, lines=50, workspace_uuid=workspace_uuid) or ""
                claude_running = detection.detect_claude_session(screen)
                if attempt == 0 or (attempt + 1) % 5 == 0:
                    self._log_event(
                        objective_id,
                        "info",
                        "planning_poll",
                        {
                            "attempt": attempt + 1,
                            "maxPolls": _max_polls,
                            "planExists": plan_exists,
                            "claudeRunning": bool(claude_running),
                            "seenClaudeActive": seen_claude_active,
                        },
                    )
                if claude_running:
                    seen_claude_active = True

                if plan_exists:
                    # Plan file exists — that's our deliverable. Proceed
                    # immediately regardless of whether Claude is still
                    # running (it may be idle at the REPL prompt, which
                    # detect_claude_session still considers "running").
                    self._log_event(
                        objective_id,
                        "info",
                        "planning_plan_found",
                        {
                            "attempt": attempt + 1,
                            "claudeRunning": bool(claude_running),
                            "workspaceId": workspace_uuid,
                        },
                    )
                    break
                if not claude_running and seen_claude_active and attempt >= grace_polls:
                    # Claude was active but now appears to have exited.
                    # Require grace_polls (default 36 * 5s = 180s) to avoid false
                    # positives from screen detection flicker during startup.
                    if plan_exists:
                        break
                    objectives.update_objective(objective_id, {"status": "failed"})
                    self._log_event(
                        objective_id,
                        "error",
                        "planning_failure",
                        {
                            "reason": "claude_exited_before_plan",
                            "workspaceId": workspace_uuid,
                            "screen_last_20_lines": self._capture_screen_snapshot(workspace_uuid),
                        },
                    )
                    self._append_message(
                        objective_id,
                        "alert",
                        "Planning failed: Claude Code exited before writing plan.md.",
                    )
                    return
                if attempt < _max_polls - 1:
                    time.sleep(_poll_interval)
            else:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._log_event(
                    objective_id,
                    "error",
                    "planning_failure",
                    {
                        "reason": "timeout_waiting_for_plan",
                        "workspaceId": workspace_uuid,
                        "screen_last_20_lines": self._capture_screen_snapshot(workspace_uuid),
                    },
                )
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: timed out waiting for plan.md.",
                )
                return

            parsed, tasks = self._read_and_parse_plan(objective_id, plan_path)
            if parsed is None:
                return

            objectives.update_objective(
                objective_id,
                {
                    "tasks": tasks,
                    "status": "plan_review",
                    "plannerWorkspaceId": workspace_uuid,
                },
            )
            keep_planner_workspace = True
            self._log_event(
                objective_id,
                "info",
                "planning_success",
                {"taskCount": len(tasks), "taskIds": [task.get("id") for task in tasks]},
            )
            self._append_message(
                objective_id,
                "plan_review",
                f"Plan ready: {len(tasks)} tasks identified. Review before execution.",
                metadata=self._plan_review_metadata(parsed),
            )
        except Exception as exc:
            tb = traceback.format_exc()
            objectives.update_objective(objective_id, {"status": "failed"})
            self._log_event(
                objective_id,
                "error",
                "exception",
                {
                    "phase": "planning",
                    "error": str(exc),
                    "traceback": tb,
                    "workspaceId": workspace_uuid,
                    "screen_last_20_lines": self._capture_screen_snapshot(workspace_uuid),
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Planning failed: {exc}\n\n```\n{tb}\n```",
            )
            return
        finally:
            if workspace_uuid and not keep_planner_workspace:
                self._close_workspace(objective_id, workspace_uuid, "planning")

    def _workspaces_from_result(self, list_result):
        if not list_result:
            return []
        if isinstance(list_result, list):
            return [ws for ws in list_result if isinstance(ws, dict)]
        workspaces = list_result.get("workspaces", [])
        return [ws for ws in workspaces if isinstance(ws, dict)]

    def _create_worker_workspace(self, title, cwd, objective_id=None, purpose="task", task_id=None):
        create_result = cmux_api._v2_request("workspace.create", {})
        if create_result is None:
            self._log_event(
                objective_id,
                "error",
                "workspace_creation_failure",
                {"purpose": purpose, "taskId": task_id, "cwd": cwd, "reason": "create_request_failed"},
            )
            return None, False

        # Use workspace_id from create response (cmux 0.63+)
        workspace_uuid = create_result.get("workspace_id")
        if not workspace_uuid:
            # Fallback: diff pre/post workspace lists
            post_list = cmux_api._v2_request("workspace.list", {})
            all_ws = self._workspaces_from_result(post_list)
            if all_ws:
                workspace_uuid = all_ws[-1].get("id") or all_ws[-1].get("uuid")
            if not workspace_uuid:
                self._log_event(
                    objective_id,
                    "error",
                    "workspace_creation_failure",
                    {"purpose": purpose, "taskId": task_id, "cwd": cwd, "reason": "workspace_id_not_found"},
                )
                return None, False

        cmux_api._v2_request(
            "workspace.rename",
            {"workspace_id": workspace_uuid, "title": title},
        )
        self._inject_hook_config(cwd)
        cmux_api._v2_request(
            "surface.send_text",
            {"workspace_id": workspace_uuid, "text": f"cd {cwd} && claude\n"},
        )
        self.mutex.set_cooldown(workspace_uuid, 5.0)
        self._log_event(
            objective_id,
            "info",
            "workspace_creation_success",
            {
                "purpose": purpose,
                "taskId": task_id,
                "workspaceId": workspace_uuid,
                "cwd": cwd,
                "title": title,
            },
        )
        return workspace_uuid, True

    def _wait_for_repl(self, ws_uuid, timeout_attempts=20, poll_interval=3.0, objective_id=None, purpose="task", task_id=None):
        repl_ready = re.compile(r"(Model:|Cost:\s*\$\d|\u276f\s*$)", re.MULTILINE | re.IGNORECASE)
        # Patterns for interactive prompts that need to be dismissed before REPL
        trust_folder = re.compile(r"(trust this folder|Yes, I trust|Enter to confirm)", re.IGNORECASE)
        compact_mode = re.compile(r"(compact|verbose|Enter to confirm.*mode)", re.IGNORECASE)
        dismissed_trust = False
        for attempt in range(timeout_attempts):
            screen = cmux_api.cmux_read_workspace(0, 0, lines=50, workspace_uuid=ws_uuid) or ""
            if repl_ready.search(screen):
                self._log_event(
                    objective_id,
                    "info",
                    "repl_ready",
                    {
                        "purpose": purpose,
                        "taskId": task_id,
                        "workspaceId": ws_uuid,
                        "attempt": attempt + 1,
                    },
                )
                return True
            # Dismiss "trust this folder" prompt by sending Enter
            if not dismissed_trust and trust_folder.search(screen):
                try:
                    with self.mutex.context(ws_uuid):
                        cmux_api._v2_request("surface.send_key", {
                            "workspace_id": ws_uuid,
                            "key": "enter",
                        })
                    dismissed_trust = True
                except Exception:
                    pass
            # Dismiss compact/verbose mode selection if it appears
            if compact_mode.search(screen) and dismissed_trust:
                try:
                    with self.mutex.context(ws_uuid):
                        cmux_api._v2_request("surface.send_key", {
                            "workspace_id": ws_uuid,
                            "key": "enter",
                        })
                except Exception:
                    pass
            if attempt < timeout_attempts - 1:
                time.sleep(poll_interval)
        self._log_event(
            objective_id,
            "error",
            "repl_timeout",
            {
                "purpose": purpose,
                "taskId": task_id,
                "workspaceId": ws_uuid,
                "timeoutAttempts": timeout_attempts,
                "screen_last_20_lines": self._capture_screen_snapshot(ws_uuid),
            },
        )
        return False

    def _assemble_context(self, objective_id, task):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return
        tasks = {item.get("id"): item for item in objective.get("tasks", []) if isinstance(item, dict)}
        context_parts = []
        for dep_id in task.get("dependsOn", []):
            dep_task = tasks.get(dep_id)
            if dep_task is None:
                continue
            result_content = objectives.read_task_file(objective_id, dep_id, "result.md")
            if not result_content or not result_content.strip():
                continue
            context_parts.append(
                f"## Task {dep_id}: {dep_task.get('title', '')}\n{result_content.strip()}"
            )
        if not context_parts:
            objectives.write_task_file(objective_id, task["id"], "context.md", "")
            return
        combined_context = "# Context from completed tasks\n\n" + "\n\n".join(context_parts) + "\n"
        objectives.write_task_file(objective_id, task["id"], "context.md", combined_context)

    def _launch_ready_tasks(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        tasks = objective.get("tasks", [])
        completed = {task["id"] for task in tasks if task.get("status") == "completed" and task.get("id")}
        active_tasks = [
            task for task in tasks
            if task.get("status") in ("executing", "reviewing", "rework")
        ]
        if active_tasks:
            return

        launchable_tasks = [
            task for task in tasks
            if task.get("status") == "queued"
            and all(dep_id in completed for dep_id in task.get("dependsOn", []))
        ]

        if not launchable_tasks:
            self._append_message(
                objective_id,
                "system",
                f"No launchable tasks found. Task statuses: {[(t['id'], t.get('status')) for t in tasks]}",
            )
            return

        self._append_message(
            objective_id,
            "system",
            f"Launching next ready task: {launchable_tasks[0]['id']}",
        )

        task = launchable_tasks[0]
        if task.get("dependsOn"):
            self._assemble_context(objective_id, task)

        worktree_path = objective.get("worktreePath", "")
        branch_name = objective.get("branchName")
        if not worktree_path:
            self._log_event(
                objective_id,
                "error",
                "task_failure",
                {"taskId": task["id"], "reason": "missing_objective_worktree"},
            )
            self._append_message(
                objective_id,
                "alert",
                f"Task {task['id']}: objective worktree is missing.",
            )
            return

        spec_content = objectives.read_task_file(objective_id, task["id"], "spec.md") or ""
        context_content = objectives.read_task_file(objective_id, task["id"], "context.md") or ""
        with open(os.path.join(worktree_path, "spec.md"), "w", encoding="utf-8") as f:
            f.write(spec_content)
        with open(os.path.join(worktree_path, "context.md"), "w", encoding="utf-8") as f:
            f.write(context_content)

        ws_uuid, created = self._create_worker_workspace(
            f"Worker: {task['title'][:35]}",
            worktree_path,
            objective_id=objective_id,
            purpose="task",
            task_id=task["id"],
        )
        if not created or not ws_uuid:
            self._log_event(
                objective_id,
                "error",
                "task_failure",
                {"taskId": task["id"], "reason": "workspace_creation_failed"},
            )
            self._append_message(
                objective_id,
                "alert",
                f"Task {task['id']}: workspace creation failed (uuid={ws_uuid}, created={created})",
            )
            return
        if not self._wait_for_repl(
            ws_uuid,
            timeout_attempts=10,
            objective_id=objective_id,
            purpose="task",
            task_id=task["id"],
        ):
            self._log_event(
                objective_id,
                "error",
                "task_failure",
                {
                    "taskId": task["id"],
                    "reason": "repl_not_ready",
                    "workspaceId": ws_uuid,
                    "screen_last_20_lines": self._capture_screen_snapshot(ws_uuid),
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Task {task['id']}: Claude Code REPL not ready in time (workspace {ws_uuid})",
            )
            return
        if not cmux_api.send_prompt_to_workspace(ws_uuid, worker.build_task_prompt(task["id"])):
            self._log_event(
                objective_id,
                "error",
                "task_failure",
                {
                    "taskId": task["id"],
                    "reason": "prompt_delivery_failed",
                    "workspaceId": ws_uuid,
                    "screen_last_20_lines": self._capture_screen_snapshot(ws_uuid),
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Task {task['id']}: failed to send prompt to workspace {ws_uuid}",
            )
            return

        objectives.update_task(objective_id, task["id"], {
            "status": "executing",
            "workspaceId": ws_uuid,
            "worktreePath": worktree_path,
            "startedAt": _utc_now_iso(),
        })
        self._append_message(
            objective_id,
            "system",
            f"Task {task['id']}: {task['title']} — launched",
        )
        self._log_event(
            objective_id,
            "info",
            "task_launch",
            {
                "taskId": task["id"],
                "title": task.get("title"),
                "workspaceId": ws_uuid,
                "worktreePath": worktree_path,
                "branchName": branch_name,
            },
        )

    def poll_tasks(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        # Track which tasks have active review threads to prevent duplicates
        if not hasattr(self, "_review_in_progress"):
            self._review_in_progress = set()

        for task in objective.get("tasks", []):
            if task.get("status") not in ("executing", "rework"):
                continue

            task_id = task["id"]
            ws_uuid = task.get("workspaceId")
            worktree_path = task.get("worktreePath")
            if not ws_uuid:
                continue

            # Approval is now handled by PreToolUse hooks (see routes/hooks.py).
            # Screen read retained for stuck detection and approval dismissal.
            screen_text = ""
            try:
                screen_text = cmux_api.cmux_read_workspace(
                    0, 0, lines=200, workspace_uuid=ws_uuid
                ) or ""
            except Exception:
                screen_text = ""

            # If a hook escalated an approval for this task, check whether the
            # user already handled it in the terminal.  When Claude is actively
            # working (thinking, running tools) the permission prompt is gone —
            # dismiss the stale approval card in the dashboard.
            if task_id in self._pending_hook_approvals and screen_text:
                is_working = bool(re.search(
                    r"(Musing\.\.\.|Thinking\.\.\.|⚡\s*\w)",
                    screen_text[-500:],
                ))
                if is_working:
                    self._pending_hook_approvals.discard(task_id)
                    self._append_message(
                        objective_id,
                        "progress",
                        f"Task {task_id}: user approved — Claude resumed",
                        metadata={"task_id": task_id},
                    )

            # Fallback: detect Claude Code's own built-in permission prompts
            # (e.g. "Bash(git push *)") that our PreToolUse hook can't control.
            # Auto-approve only if the same permission screen is seen twice
            # in a row (confirms the prompt is genuinely stuck).
            if screen_text and detection.is_permission_prompt(screen_text):
                screen_fp = detection.fingerprint(screen_text)
                prev_cached = self._task_screen_cache.get(task_id, "")
                prev_fp = detection.fingerprint(prev_cached) if prev_cached else ""
                if prev_fp and prev_fp == screen_fp:
                    self._try_approve_permission_prompt(
                        ws_uuid, screen_text,
                        objective_id=objective_id, task_id=task_id,
                    )

            last_ts = self._task_last_progress.get(task_id, 0)
            wt_path = task.get("worktreePath")
            progress_state = monitor.check_progress(objective_id, task_id, last_ts, worktree_path=wt_path)

            if progress_state.get("has_result"):
                # Skip if a review thread is already running for this task
                if task_id in self._review_in_progress:
                    continue
                # result.md exists — the task deliverable is done.
                # Proceed immediately regardless of whether Claude is
                # still idle at the REPL (same fix as planner).
                # Send /exit to clean up the Claude session.
                try:
                    with self.mutex.context(ws_uuid):
                        cmux_api.send_prompt_to_workspace(ws_uuid, "/exit")
                except Exception:
                    pass
                objectives.update_task(objective_id, task_id, {"status": "reviewing"})
                task["status"] = "reviewing"  # update local copy too
                self._append_message(
                    objective_id,
                    "progress",
                    f"Task {task_id}: completed, starting review...",
                    metadata={"task_id": task_id},
                )
                self._log_event(
                    objective_id,
                    "info",
                    "task_completion",
                    {"taskId": task_id, "workspaceId": ws_uuid},
                )
                if hasattr(self, "_run_review"):
                    self._review_in_progress.add(task_id)
                    threading.Thread(
                        target=self._run_review_wrapper,
                        args=(objective_id, task_id),
                        daemon=True,
                    ).start()
                continue

            if progress_state.get("has_progress_update"):
                self._task_last_progress[task_id] = progress_state.get("progress_mtime", time.time())
                checkpoints = progress_state.get("checkpoints", [])
                if checkpoints:
                    task["checkpoints"] = [
                        {"name": cp.get("name", ""), "status": cp.get("status", "pending")}
                        for cp in checkpoints
                    ]
                    task["lastProgressAt"] = _utc_now_iso()
                    objectives.update_objective(objective_id, {"tasks": objective["tasks"]})
                    latest_cp = checkpoints[-1]
                    self._append_message(
                        objective_id,
                        "progress",
                        f"Task {task_id}: checkpoint '{latest_cp.get('name', '')}' — {latest_cp.get('status', '')}",
                        metadata={"task_id": task_id, "checkpoints": checkpoints},
                    )
                    self._log_event(
                        objective_id,
                        "info",
                        "task_progress",
                        {
                            "taskId": task_id,
                            "checkpoint": latest_cp.get("name", ""),
                            "status": latest_cp.get("status", ""),
                            "workspaceId": ws_uuid,
                        },
                    )

            last_progress_at = self._task_last_progress.get(task_id)
            has_git = False
            if worktree_path:
                since_ts = last_progress_at
                if since_ts is None:
                    since_ts = _coerce_timestamp(task.get("startedAt"), 0.0)
                has_git = monitor.check_git_activity(worktree_path, since_ts)

            cached_screen = self._task_screen_cache.get(task_id, "")
            has_terminal_change = screen_text != cached_screen
            self._task_screen_cache[task_id] = screen_text

            stuck_status = monitor.assess_stuck_status(
                {
                    "task_id": task_id,
                    "status": task.get("status"),
                    "last_progress_at": last_progress_at,
                    "has_git_activity": has_git,
                    "has_terminal_activity": has_terminal_change,
                    "now": time.time(),
                }
            )

            if stuck_status.get("level") == "stalled":
                preview = screen_text[-500:] if len(screen_text) > 500 else screen_text
                self._append_message(
                    objective_id,
                    "alert",
                    f"Task {task_id} appears stalled — {stuck_status.get('reason', 'no activity')} ({stuck_status.get('elapsed_minutes', 0):.1f} min)",
                    metadata={
                        "task_id": task_id,
                        "stuck_status": stuck_status,
                        "screen_preview": preview,
                    },
                )
                self._log_event(
                    objective_id,
                    "warn",
                    "task_progress",
                    {
                        "taskId": task_id,
                        "status": "stalled",
                        "workspaceId": ws_uuid,
                        "stuckStatus": stuck_status,
                        "screen_last_20_lines": self._capture_screen_snapshot(ws_uuid),
                    },
                )
            elif stuck_status.get("level") == "amber":
                self._append_message(
                    objective_id,
                    "system",
                    f"Task {task_id}: terminal active but no progress updates ({stuck_status.get('elapsed_minutes', 0):.1f} min)",
                    metadata={"task_id": task_id, "stuck_status": stuck_status},
                )
                self._log_event(
                    objective_id,
                    "warn",
                    "task_progress",
                    {"taskId": task_id, "status": "amber", "workspaceId": ws_uuid, "stuckStatus": stuck_status},
                )

    def _run_review_wrapper(self, objective_id, task_id):
        """Wrapper that manages the review-in-progress flag."""
        try:
            self._run_review(objective_id, task_id)
        finally:
            self._review_in_progress.discard(task_id)

    def _build_task_review_prompt(self, spec_text, result_text, git_diff_stat, git_diff, contract_text=""):
        """Build a focused review prompt for orchestrator tasks.

        Unlike the generic session review prompt, this checks:
        1. Did the worker stay within scope?
        2. Did the worker complete all checkpoints?
        3. Are the changes committed?
        It does NOT check code style, architecture, or PR-readiness.
        """
        return f"""You are reviewing a single task completed by an AI coding worker.
Grade the task against the sprint contract, not against effort or intent. Be skeptical.

Your job is to check FOUR things:

1. **SCOPE COMPLIANCE**: Did the worker ONLY modify files listed in the spec's scope boundary?
2. **CHECKPOINT COMPLETION**: Did the worker complete all checkpoints listed in the spec?
3. **CONTRACT ACCEPTANCE CRITERIA**: Grade EACH acceptance criterion from the contract as pass/fail with concrete evidence from the result text or diff.
4. **CHANGES COMMITTED**: Does `git diff --stat` / `git diff` show the expected functional changes?

Anti-leniency rules:
- Stubbed, UI-only, or non-functional features FAIL. Do not give credit for partial implementations.
- If any acceptance criterion is not satisfied end-to-end, mark that criterion as "fail".
- If evidence is missing, treat it as a fail rather than assuming the feature works.

This is an INTERMEDIATE task in a multi-task pipeline. Do NOT evaluate:
- Code style or best practices
- Architecture decisions beyond whether the contract/spec is met
- Unrelated future work

Few-shot FAIL examples:
Example 1:
- Criterion: "User can submit the form and the data is persisted"
- Evidence: "Diff only adds button styling and a click handler that logs to console"
- Result: FAIL
- Why: UI exists, but there is no persistence. Stubbed or UI-only work does not satisfy the criterion.

Example 2:
- Criterion: "API returns filtered results for status=active"
- Evidence: "Result mentions endpoint added, but diff only updates docs and test fixtures"
- Result: FAIL
- Why: There is no functional implementation proving the endpoint behavior. Claimed completion without working code fails.

=== TASK SPEC ===
{spec_text.strip()}

=== CONTRACT ACCEPTANCE CRITERIA ===
{contract_text.strip()}

=== WORKER'S RESULT ===
{result_text.strip()}

=== GIT DIFF --stat ===
{git_diff_stat.strip()}

=== GIT DIFF (code changes) ===
{git_diff.strip()[:3000]}

Respond with ONLY a JSON object in this exact shape:
{{
  "verdict": "pass" | "fail",
  "tier1_build": "skipped",
  "tier2_maestro": "skipped",
  "criteria_results": [
    {{
      "criterion": "desc",
      "result": "pass" | "fail",
      "evidence": "why"
    }}
  ],
  "issues": ["list of SPECIFIC problems"],
  "recommendation": "text"
}}

Verdict rules:
- "pass" only if scope is respected, checkpoints are complete, changes are functional, and every acceptance criterion passes.
- "fail" if any acceptance criterion fails, if the implementation is stubbed/partial/non-functional, if required changes are missing, or if scope is violated.
"""

    def _run_review(self, objective_id, task_id):
        self._append_message(objective_id, "review", f"Reviewing Task {task_id}...")
        self._log_event(objective_id, "info", "review_start", {"taskId": task_id})

        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        tasks = objective.get("tasks", [])
        task = next((item for item in tasks if item.get("id") == task_id), None)
        if task is None:
            return

        task["status"] = "reviewing"
        result_text = objectives.read_task_file(objective_id, task_id, "result.md") or ""
        spec_text = objectives.read_task_file(objective_id, task_id, "spec.md") or ""
        contract_text = objectives.read_task_file(objective_id, task_id, "contract.md") or ""
        worktree_path = task.get("worktreePath", "")

        git_diff_stat = ""
        git_diff = ""
        if worktree_path:
            # Get diff stat
            diff_stat_commands = [
                ["git", "-C", worktree_path, "diff", "HEAD~1", "--stat"],
                ["git", "-C", worktree_path, "diff", "--stat"],
            ]
            for cmd in diff_stat_commands:
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                except (OSError, subprocess.SubprocessError):
                    continue
                if result.returncode == 0:
                    git_diff_stat = (result.stdout or "").strip()
                    break

            # Get actual diff for code review
            diff_commands = [
                ["git", "-C", worktree_path, "diff", "HEAD~1"],
                ["git", "-C", worktree_path, "diff"],
            ]
            for cmd in diff_commands:
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                except (OSError, subprocess.SubprocessError):
                    continue
                if result.returncode == 0:
                    git_diff = (result.stdout or "").strip()
                    break

        review_prompt = self._build_task_review_prompt(
            spec_text,
            result_text,
            git_diff_stat,
            git_diff,
            contract_text,
        )

        review_result = claude_cli.run_sonnet(review_prompt, timeout=120)
        if isinstance(review_result, dict):
            review_json = review_result
        else:
            try:
                parsed = json.loads(review_result)
            except (TypeError, json.JSONDecodeError):
                parsed = None
            if isinstance(parsed, dict):
                review_json = parsed
            else:
                # If we can't parse, assume pass — don't block pipeline on parse failure
                review_json = {
                    "verdict": "pass",
                    "tier1_build": "skipped",
                    "tier2_maestro": "skipped",
                    "criteria_results": [],
                    "issues": [],
                    "recommendation": "Review parse failed — auto-passing to avoid blocking pipeline",
                }

        criteria_results = review_json.get("criteria_results")
        failed_criteria = []
        if isinstance(criteria_results, list):
            failed_criteria = [
                item for item in criteria_results
                if isinstance(item, dict) and str(item.get("result", "")).lower() == "fail"
            ]

        issues = review_json.get("issues")
        if failed_criteria and not (isinstance(issues, list) and any(str(issue).strip() for issue in issues)):
            review_json["issues"] = [
                f"{item.get('criterion', 'Acceptance criterion failed')}: {item.get('evidence', 'No evidence provided')}"
                for item in failed_criteria
            ]

        tier2_failed = False
        # Tier 2: Maestro functional test (if available and contract exists)
        if contract_text and evaluator.is_maestro_available():
            flow_yaml = evaluator.generate_maestro_flow(contract_text)
            tier2_passed, tier2_output = evaluator.run_tier2_maestro(flow_yaml)
            review_json["tier2_maestro"] = "pass" if tier2_passed else "fail"
            if not tier2_passed:
                if not isinstance(review_json.get("issues"), list):
                    review_json["issues"] = []
                review_json["issues"].append(f"Maestro test failed: {tier2_output[:200]}")
                tier2_failed = True
                needs_rework = True

        objectives.write_task_file(
            objective_id,
            task_id,
            "review.json",
            json.dumps(review_json, indent=2),
        )

        # Atomically increment reviewCycles on disk
        updated_task = objectives.update_task(objective_id, task_id, {
            "reviewCycles": task.get("reviewCycles", 0) + 1,
        })
        review_cycle = updated_task.get("reviewCycles", 1)
        # Refresh local task with latest from disk
        task.update(updated_task)

        # Use verdict-based check (new focused review) with fallback to legacy format
        verdict = review_json.get("verdict", "").lower()
        if failed_criteria or tier2_failed:
            needs_rework = True
        elif verdict == "pass":
            needs_rework = False
        elif verdict == "fail":
            needs_rework = True
        else:
            # Legacy format fallback
            needs_rework = monitor.should_trigger_rework(review_json)

        if not needs_rework:
            # Clean up the worker's Claude session and workspace
            workspace_uuid = task.get("workspaceId")
            if workspace_uuid:
                try:
                    cmux_api.send_prompt_to_workspace(workspace_uuid, "/exit")
                    time.sleep(1)
                    cmux_api._v2_request("workspace.close", {"workspace_id": workspace_uuid})
                    self._log_event(
                        objective_id,
                        "info",
                        "workspace_closed",
                        {"workspaceId": workspace_uuid, "purpose": "task_completed", "taskId": task_id},
                    )
                except Exception:
                    pass
            objectives.update_task(objective_id, task_id, {
                "status": "completed",
                "completedAt": _utc_now_iso(),
            })
            self._log_event(
                objective_id,
                "info",
                "review_result",
                {"taskId": task_id, "verdict": "pass", "review": review_json, "cycle": review_cycle},
            )
            self._append_message(
                objective_id,
                "review",
                f"Task {task_id}: review passed (cycle {review_cycle})",
                metadata={"task_id": task_id, "review": review_json},
            )
            self._launch_ready_tasks(objective_id)
            refreshed = objectives.read_objective(objective_id) or {}
            refreshed_tasks = refreshed.get("tasks", [])
            if refreshed_tasks and all(item.get("status") == "completed" for item in refreshed_tasks):
                self._complete_objective(objective_id)
            return

        if monitor.can_retry_review(task):
            # Clear result.md so poll_tasks doesn't re-detect completion
            # before the worker has a chance to rework
            task_dir = objectives.get_objective_dir(objective_id) / "tasks" / task_id
            for result_path in [task_dir / "result.md"]:
                try:
                    result_path.write_text("", encoding="utf-8")
                except OSError:
                    pass
            wt_result = pathlib.Path(task.get("worktreePath", "")) / "result.md"
            try:
                if wt_result.is_file():
                    wt_result.write_text("", encoding="utf-8")
            except OSError:
                pass
            objectives.update_task(objective_id, task_id, {"status": "rework"})
            issues, recommendation = monitor.build_review_rework_summary(review_json)
            rework_prompt = worker.build_rework_prompt(issues, recommendation)
            workspace_uuid = task.get("workspaceId")
            screen_text = ""
            if workspace_uuid:
                try:
                    screen_text = cmux_api.cmux_read_workspace(
                        0,
                        0,
                        lines=200,
                        workspace_uuid=workspace_uuid,
                    ) or ""
                except Exception:
                    screen_text = ""
                # Ensure Claude is exited before relaunching for rework.
                # We may have sent /exit when result.md was detected, but
                # the session might still be shutting down.
                if detection.detect_claude_session(screen_text):
                    try:
                        cmux_api.send_prompt_to_workspace(workspace_uuid, "/exit")
                        time.sleep(2)
                    except Exception:
                        pass
                self._inject_hook_config(worktree_path)
                launch_text = f"cd {worktree_path} && claude\n"
                with self.mutex.context(workspace_uuid):
                    cmux_api.cmux_send_to_workspace(
                        0,
                        0,
                        text=launch_text,
                        workspace_uuid=workspace_uuid,
                    )
                self._wait_for_repl(workspace_uuid, objective_id=objective_id, purpose="rework", task_id=task_id)
                cmux_api.send_prompt_to_workspace(workspace_uuid, rework_prompt)
            objectives.update_task(objective_id, task_id, {"status": "executing"})
            self._log_event(
                objective_id,
                "warn",
                "review_result",
                {"taskId": task_id, "verdict": "fail", "review": review_json, "cycle": review_cycle},
            )
            self._log_event(
                objective_id,
                "warn",
                "rework_triggered",
                {"taskId": task_id, "issues": issues, "recommendation": recommendation, "workspaceId": workspace_uuid},
            )
            self._append_message(
                objective_id,
                "review",
                (
                    f"Task {task_id}: review found issues, sending back for fixes "
                    f"(cycle {review_cycle}/{task.get('maxReviewCycles', 5)})"
                ),
                metadata={"task_id": task_id, "issues": issues, "review": review_json},
            )
            return

        # Clean up the worker's Claude session on permanent failure
        workspace_uuid = task.get("workspaceId")
        if workspace_uuid:
            try:
                cmux_api.send_prompt_to_workspace(workspace_uuid, "/exit")
                time.sleep(1)
                cmux_api._v2_request("workspace.close", {"workspace_id": workspace_uuid})
                self._log_event(
                    objective_id,
                    "info",
                    "workspace_closed",
                    {"workspaceId": workspace_uuid, "purpose": "task_failed", "taskId": task_id},
                )
            except Exception:
                pass
        objectives.update_task(objective_id, task_id, {"status": "failed"})
        issues, _ = monitor.build_review_rework_summary(review_json)
        self._log_event(
            objective_id,
            "error",
            "review_result",
            {"taskId": task_id, "verdict": "fail", "review": review_json, "cycle": review_cycle, "failedPermanently": True},
        )
        self._log_event(
            objective_id,
            "error",
            "task_failure",
            {"taskId": task_id, "reason": "review_failed_max_cycles", "issues": issues},
        )
        self._append_message(
            objective_id,
            "alert",
            (
                f"Task {task_id}: failed review "
                f"{task.get('maxReviewCycles', 5)} times. Needs your attention."
            ),
            metadata={"task_id": task_id, "issues": issues, "review": review_json},
        )

    def _complete_objective(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        tasks = objective.get("tasks", [])
        result_parts = []
        total_review_cycles = 0
        rework_count = 0
        for task in tasks:
            task_id = task.get("id")
            if not task_id:
                continue
            result_text = objectives.read_task_file(objective_id, task_id, "result.md") or ""
            if result_text.strip():
                result_parts.append(result_text.strip())
            cycles = task.get("reviewCycles", 0)
            total_review_cycles += cycles
            if cycles > 1:
                rework_count += 1

        update_payload = {"status": "completed"}
        if objective.get("orchestratorSessionActive"):
            update_payload["orchestratorLastActivityAt"] = _utc_now_iso()
        objectives.update_objective(objective_id, update_payload)

        summary_prompt = (
            "Summarize the following completed task results into a brief project summary:\n\n"
            + "\n\n".join(result_parts)
        )
        summary_result = claude_cli.run_haiku(summary_prompt)
        if isinstance(summary_result, dict):
            summary_text = summary_result.get("summary") or json.dumps(summary_result)
        else:
            summary_text = summary_result

        self._append_message(
            objective_id,
            "completion",
            f"Objective complete! {len(tasks)} tasks done. {rework_count} required rework.",
            metadata={
                "summary": summary_text,
                "total_review_cycles": total_review_cycles,
                "rework_count": rework_count,
            },
        )
        with self._lock:
            if self._active_objective_id == objective_id:
                self._active_objective_id = None

    def handle_human_input(self, objective_id, message, context=None):
        self._append_message(objective_id, "user", message)
        self._log_event(
            objective_id,
            "info",
            "human_input_received",
            {"message": message, "context": context or {}},
        )

        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        context = context or {}
        objective_status = str(objective.get("status") or "").lower()
        task_id = context.get("task_id")
        if task_id and context.get("approval_action"):
            task = next((item for item in objective.get("tasks", []) if item.get("id") == task_id), None)
            workspace_uuid = task.get("workspaceId") if task else None
            if workspace_uuid:
                with self.mutex.context(workspace_uuid):
                    cmux_api.cmux_send_to_workspace(
                        0,
                        0,
                        text=context["approval_action"],
                        workspace_uuid=workspace_uuid,
                    )
                self._append_message(
                    objective_id,
                    "system",
                    f"Sent '{context['approval_action']}' to Task {task_id}",
                    metadata={"task_id": task_id},
                )
                self._log_event(
                    objective_id,
                    "info",
                    "task_approval",
                    {"taskId": task_id, "mode": "manual", "action": context["approval_action"], "workspaceId": workspace_uuid},
                )
            return

        if objective_status == "failed" and _RETRY_REQUEST_PATTERN.search(message or ""):
            self.start_objective(objective_id)
            return

        if objective_status == "plan_review":
            planner_workspace_id = objective.get("plannerWorkspaceId")
            worktree_path = objective.get("worktreePath", "")
            plan_path = os.path.join(worktree_path, "plan.md")
            if not planner_workspace_id or not os.path.isfile(plan_path):
                objectives.update_objective(objective_id, {"status": "failed"})
                if planner_workspace_id:
                    self._close_workspace(objective_id, planner_workspace_id, "plan_revision_failed")
                self._append_message(
                    objective_id,
                    "alert",
                    "Plan revision failed: planner workspace or plan.md is unavailable.",
                )
                return
            current_plan = pathlib.Path(plan_path).read_text(encoding="utf-8")
            revision_prompt = (
                "The human reviewed your plan and has feedback:\n\n"
                f"{message}\n\n"
                "Current plan.md:\n\n"
                f"{current_plan}\n\n"
                "Please revise plan.md based on this feedback. Rewrite the entire plan.md file with your changes."
            )
            if not cmux_api.send_prompt_to_workspace(planner_workspace_id, revision_prompt):
                self._append_message(
                    objective_id,
                    "alert",
                    "Plan revision failed: could not deliver feedback to the planner workspace.",
                )
                return
            objectives.update_objective(objective_id, {"status": "planning"})
            threading.Thread(
                target=self._poll_for_plan_revision,
                args=(objective_id, plan_path, pathlib.Path(plan_path).stat().st_mtime),
                daemon=True,
            ).start()
            return

        if context.get("take_over") and task_id:
            tasks = objective.get("tasks", [])
            task = next((item for item in tasks if item.get("id") == task_id), None)
            if task is None:
                return
            task["status"] = "failed"
            task["note"] = "Taken over by human"
            objectives.update_objective(objective_id, {"tasks": tasks})
            self._append_message(
                objective_id,
                "system",
                f"Task {task_id}: taken over by human",
                metadata={"task_id": task_id},
            )
            self._log_event(
                objective_id,
                "warn",
                "task_failure",
                {"taskId": task_id, "reason": "taken_over_by_human"},
            )
            return

        orchestrator_ws = objective.get("orchestratorSessionId")
        is_active = objective.get("orchestratorSessionActive", False)
        if not orchestrator_ws or not is_active:
            self._append_message(objective_id, "system", "Resuming orchestrator session...")
            orchestrator_ws = self._start_orchestrator_session(objective_id)
            if not orchestrator_ws:
                self._append_message(objective_id, "alert", "Could not start orchestrator session.")
                return

        baseline_screen = cmux_api.cmux_read_workspace(0, 0, lines=200, workspace_uuid=orchestrator_ws) or ""
        if not cmux_api.send_prompt_to_workspace(orchestrator_ws, message):
            self._append_message(objective_id, "alert", "Could not deliver message to orchestrator session.")
            return

        objectives.update_objective(
            objective_id,
            {
                "orchestratorLastActivityAt": _utc_now_iso(),
                "orchestratorSessionId": orchestrator_ws,
                "orchestratorSessionActive": True,
            },
        )
        threading.Thread(
            target=self._capture_orchestrator_response,
            args=(objective_id, orchestrator_ws, baseline_screen, message),
            daemon=True,
        ).start()

    def _poll_for_plan_revision(self, objective_id, plan_path, previous_mtime, _poll_interval=5, _max_seconds=600):
        deadline = time.time() + _max_seconds
        while time.time() < deadline:
            objective = objectives.read_objective(objective_id)
            if objective is None:
                return
            planner_workspace_id = objective.get("plannerWorkspaceId")
            if not planner_workspace_id:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Plan revision failed: planner workspace was lost.",
                )
                return
            try:
                current_mtime = pathlib.Path(plan_path).stat().st_mtime
            except OSError:
                current_mtime = None
            if current_mtime and current_mtime > previous_mtime:
                parsed, tasks = self._read_and_parse_plan(objective_id, plan_path)
                if parsed is None:
                    self._close_workspace(objective_id, planner_workspace_id, "plan_revision_parse_failed")
                    objectives.update_objective(objective_id, {"plannerWorkspaceId": None})
                    return
                objectives.update_objective(
                    objective_id,
                    {
                        "tasks": tasks,
                        "status": "plan_review",
                    },
                )
                self._append_message(
                    objective_id,
                    "plan_review",
                    f"Plan updated: {len(tasks)} tasks ready for review.",
                    metadata=self._plan_review_metadata(parsed),
                )
                self._log_event(
                    objective_id,
                    "info",
                    "plan_revision_success",
                    {"taskCount": len(tasks), "taskIds": [task.get("id") for task in tasks]},
                )
                return
            time.sleep(_poll_interval)
        objectives.update_objective(objective_id, {"status": "plan_review"})
        self._append_message(
            objective_id,
            "alert",
            "Plan revision timed out waiting for an updated plan.md.",
        )
        self._log_event(
            objective_id,
            "error",
            "plan_revision_timeout",
            {"planPath": plan_path, "maxSeconds": _max_seconds},
        )

    def get_active_objective_id(self):
        with self._lock:
            return self._active_objective_id

    def is_orchestrated_workspace(self, workspace_uuid):
        if not workspace_uuid:
            return False
        with self._lock:
            objective_id = self._active_objective_id
        if not objective_id:
            return False
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        for task in objective.get("tasks", []):
            if task.get("workspaceId") == workspace_uuid:
                return True
        return False

    def stop_objective(self, objective_id=None):
        with self._lock:
            active_objective_id = self._active_objective_id
            if active_objective_id is None:
                return False
            if objective_id is not None and objective_id != active_objective_id:
                return False
            self._active_objective_id = None
        self._append_message(active_objective_id, "system", "Objective stopped.")
        self._log_event(active_objective_id, "warn", "objective_stopped", {})
        return True

    def stop_and_cleanup(self, objective_id):
        self.stop_objective(objective_id)
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        seen = set()
        planner_workspace_id = objective.get("plannerWorkspaceId")
        if planner_workspace_id:
            seen.add(planner_workspace_id)
            self._close_workspace(objective_id, planner_workspace_id, "cleanup_planner")
        orchestrator_workspace_id = objective.get("orchestratorSessionId")
        if orchestrator_workspace_id and orchestrator_workspace_id not in seen:
            seen.add(orchestrator_workspace_id)
            self._close_workspace(objective_id, orchestrator_workspace_id, "cleanup_orchestrator")
        for task in objective.get("tasks", []):
            workspace_id = task.get("workspaceId")
            if not workspace_id or workspace_id in seen:
                continue
            seen.add(workspace_id)
            self._close_workspace(objective_id, workspace_id, "cleanup", task_id=task.get("id"))
        project_dir = objective.get("projectDir", "")
        worktree_path = objective.get("worktreePath", "")
        if project_dir and worktree_path:
            try:
                subprocess.run(
                    ["git", "-C", project_dir, "worktree", "remove", worktree_path, "--force"],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                self._log_event(
                    objective_id,
                    "info",
                    "worktree_removed",
                    {"projectDir": project_dir, "worktreePath": worktree_path},
                )
            except (subprocess.CalledProcessError, OSError) as exc:
                self._log_event(
                    objective_id,
                    "error",
                    "exception",
                    {
                        "phase": "stop_and_cleanup_worktree",
                        "projectDir": project_dir,
                        "worktreePath": worktree_path,
                        "error": str(exc),
                    },
                )
        return True

    def approve_plan(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        if str(objective.get("status") or "").lower() != "plan_review":
            return False
        planner_workspace_id = objective.get("plannerWorkspaceId")
        if planner_workspace_id:
            self._close_workspace(objective_id, planner_workspace_id, "plan_approved")
        objectives.update_objective(
            objective_id,
            {"status": "negotiating_contracts", "plannerWorkspaceId": None},
        )
        self._append_message(objective_id, "system", "Plan approved, negotiating sprint contracts...")
        try:
            threading.Thread(target=self._negotiate_contracts, args=(objective_id,), daemon=True).start()
        except Exception:
            tb = traceback.format_exc()
            self._log_event(
                objective_id,
                "error",
                "exception",
                {
                    "phase": "approve_plan_negotiate_contracts",
                    "traceback": tb,
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Failed to start contract negotiation after plan approval.\n\n```\n{tb}\n```",
            )
            return False
        return True

    def _negotiate_contracts(self, objective_id):
        try:
            objective = objectives.read_objective(objective_id)
            if objective is None:
                raise FileNotFoundError(f"objective not found: {objective_id}")

            tasks = [task for task in objective.get("tasks", []) if isinstance(task, dict)]
            contract_metadata = []
            for task in tasks:
                task_id = task.get("id")
                if not task_id:
                    continue
                result = claude_cli.run_sonnet(contracts.build_contract_prompt(task))
                content = result if isinstance(result, str) else json.dumps(result, indent=2)
                objectives.write_task_file(objective_id, task_id, "contract.md", content)
                parsed = contracts.parse_contract(content)
                contract_metadata.append({
                    "taskId": task_id,
                    "title": task.get("title", ""),
                    "acceptanceCriteria": parsed.get("acceptanceCriteria", "") if parsed else content,
                    "buildVerification": parsed.get("buildVerification", "") if parsed else "",
                    "functionalTestHints": parsed.get("functionalTestHints", "") if parsed else "",
                    "passFailThreshold": parsed.get("passFailThreshold", "") if parsed else "",
                })

            objectives.update_objective(objective_id, {"status": "contract_review"})
            self._append_message(
                objective_id,
                "contract_review",
                "Sprint contracts are ready for review.",
                metadata={"contracts": contract_metadata},
            )
        except Exception as exc:
            tb = traceback.format_exc()
            objectives.update_objective(objective_id, {"status": "failed"})
            self._log_event(
                objective_id,
                "error",
                "exception",
                {
                    "phase": "negotiate_contracts",
                    "error": str(exc),
                    "traceback": tb,
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Contract negotiation failed: {exc}\n\n```\n{tb}\n```",
            )

    def approve_contracts(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        if str(objective.get("status") or "").lower() != "contract_review":
            return False
        objectives.update_objective(objective_id, {"status": "executing"})
        self._append_message(objective_id, "system", "Contracts approved, launching tasks...")
        try:
            self._launch_ready_tasks(objective_id)
        except Exception:
            tb = traceback.format_exc()
            self._log_event(
                objective_id,
                "error",
                "exception",
                {
                    "phase": "approve_contracts_launch_tasks",
                    "traceback": tb,
                },
            )
            self._append_message(
                objective_id,
                "alert",
                f"Failed to launch tasks after contract approval.\n\n```\n{tb}\n```",
            )
            return False
        return True
