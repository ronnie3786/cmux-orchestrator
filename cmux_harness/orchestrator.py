import json
import os
import re
import threading
import time
import uuid
from datetime import datetime, timezone

from . import claude_cli
from . import cmux_api
from . import detection
from . import objectives
from . import planner
from .workspace_mutex import WorkspaceMutex


def _utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


class Orchestrator:
    def __init__(self, engine):
        self.engine = engine
        self.mutex = WorkspaceMutex()
        self._active_objective_id = None
        self._messages = {}
        self._task_screen_cache = {}
        self._task_last_progress = {}
        self._lock = threading.Lock()

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

    def get_messages(self, objective_id, after=None):
        with self._lock:
            if objective_id not in self._messages:
                self._messages[objective_id] = self._load_messages(objective_id)
            messages = list(self._messages[objective_id])
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

    def start_objective(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return False
        if not objective.get("goal") or not objective.get("projectDir"):
            return False
        with self._lock:
            if self._active_objective_id is not None:
                return False
            self._active_objective_id = objective_id
        objectives.update_objective(objective_id, {"status": "planning"})
        self._append_message(
            objective_id,
            "system",
            f"Starting objective: {objective['goal']}",
        )
        threading.Thread(target=self._run_planning, args=(objective_id,), daemon=True).start()
        return True

    def _run_planning(self, objective_id):
        workspace_uuid = None
        try:
            self._append_message(
                objective_id,
                "system",
                "Planning: analyzing codebase and decomposing goal...",
            )
            objective = objectives.read_objective(objective_id)
            if objective is None:
                raise FileNotFoundError(f"objective not found: {objective_id}")

            goal = objective.get("goal", "")
            project_dir = objective.get("projectDir", "")
            if not goal or not project_dir:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: objective is missing goal or projectDir.",
                )
                return

            def _workspaces_from_result(list_result):
                if not list_result:
                    return []
                if isinstance(list_result, list):
                    return [ws for ws in list_result if isinstance(ws, dict)]
                workspaces = list_result.get("workspaces", [])
                return [ws for ws in workspaces if isinstance(ws, dict)]

            pre_list = cmux_api._v2_request("workspace.list", {})
            existing_ids = {
                ws.get("id") or ws.get("uuid")
                for ws in _workspaces_from_result(pre_list)
                if ws.get("id") or ws.get("uuid")
            }

            create_result = cmux_api._v2_request("workspace.create", {})
            if create_result is None:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not create planner workspace.",
                )
                return

            post_list = cmux_api._v2_request("workspace.list", {})
            new_workspace = next(
                (
                    ws for ws in _workspaces_from_result(post_list)
                    if (ws.get("id") or ws.get("uuid")) not in existing_ids
                ),
                None,
            )
            if new_workspace is None:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not resolve planner workspace.",
                )
                return

            workspace_uuid = new_workspace.get("id") or new_workspace.get("uuid")
            cmux_api._v2_request(
                "workspace.rename",
                {"workspace_id": workspace_uuid, "title": f"Planner: {goal[:40]}"},
            )
            cmux_api._v2_request(
                "surface.send_text",
                {"workspace_id": workspace_uuid, "text": f"cd {project_dir} && claude\n"},
            )
            self.mutex.set_cooldown(workspace_uuid, 5.0)

            repl_ready = re.compile(r"(Model:|Cost:\s*\$\d|\u276f\s*$)", re.MULTILINE | re.IGNORECASE)
            prompt_sent = False
            for attempt in range(20):
                screen = cmux_api.cmux_read_workspace(0, 0, lines=30, workspace_uuid=workspace_uuid) or ""
                if repl_ready.search(screen):
                    prompt_sent = bool(
                        cmux_api.send_prompt_to_workspace(
                            workspace_uuid,
                            planner.build_planning_prompt(goal),
                        )
                    )
                    break
                if attempt < 19:
                    time.sleep(3)
            if not prompt_sent:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: Claude Code did not become ready in time.",
                )
                return

            plan_path = os.path.join(project_dir, "plan.md")
            for attempt in range(60):
                plan_exists = os.path.isfile(plan_path)
                screen = cmux_api.cmux_read_workspace(0, 0, lines=30, workspace_uuid=workspace_uuid) or ""
                claude_running = detection.detect_claude_session(screen)
                if plan_exists and not claude_running:
                    break
                if not claude_running:
                    if plan_exists:
                        break
                    objectives.update_objective(objective_id, {"status": "failed"})
                    self._append_message(
                        objective_id,
                        "alert",
                        "Planning failed: Claude Code exited before writing plan.md.",
                    )
                    return
                if attempt < 59:
                    time.sleep(5)
            else:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: timed out waiting for plan.md.",
                )
                return

            with open(plan_path, "r", encoding="utf-8") as f:
                plan_text = f.read()
            parsed = planner.parse_plan(plan_text)
            if "error" in parsed:
                objectives.update_objective(objective_id, {"status": "failed"})
                raw_plan = parsed.get("raw_plan", plan_text)
                self._append_message(
                    objective_id,
                    "alert",
                    f"Planning parse failed. Raw plan for manual review:\n\n{raw_plan}",
                )
                return

            tasks = planner.plan_to_tasks(parsed, objective_id)
            objectives.update_objective(objective_id, {"tasks": tasks, "status": "executing"})
            self._append_message(
                objective_id,
                "plan",
                f"Plan ready: {len(tasks)} tasks identified.",
                metadata={"tasks": tasks},
            )
        except OSError as exc:
            objectives.update_objective(objective_id, {"status": "failed"})
            self._append_message(
                objective_id,
                "alert",
                f"Planning failed: {exc}",
            )
            return
        finally:
            if workspace_uuid:
                try:
                    cmux_api._v2_request("workspace.close", {"workspace_id": workspace_uuid})
                except Exception:
                    pass

        if hasattr(self, "_launch_ready_tasks"):
            try:
                self._launch_ready_tasks(objective_id)
            except Exception:
                pass

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
        return True
