import json
import os
import re
import threading
import time
import uuid
from datetime import datetime, timezone

from . import claude_cli
from . import approval
from . import cmux_api
from . import detection
from . import monitor
from . import objectives
from . import planner
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

            workspace_uuid, created = self._create_worker_workspace(
                f"Planner: {goal[:40]}",
                project_dir,
            )
            if not created or not workspace_uuid:
                objectives.update_objective(objective_id, {"status": "failed"})
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not create planner workspace.",
                )
                return

            if not self._wait_for_repl(workspace_uuid):
                objectives.update_objective(objective_id, {"status": "failed"})
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
                self._append_message(
                    objective_id,
                    "alert",
                    "Planning failed: could not deliver planning prompt.",
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

    def _workspaces_from_result(self, list_result):
        if not list_result:
            return []
        if isinstance(list_result, list):
            return [ws for ws in list_result if isinstance(ws, dict)]
        workspaces = list_result.get("workspaces", [])
        return [ws for ws in workspaces if isinstance(ws, dict)]

    def _create_worker_workspace(self, title, cwd):
        pre_list = cmux_api._v2_request("workspace.list", {})
        existing_ids = {
            ws.get("id") or ws.get("uuid")
            for ws in self._workspaces_from_result(pre_list)
            if ws.get("id") or ws.get("uuid")
        }

        create_result = cmux_api._v2_request("workspace.create", {})
        if create_result is None:
            return None, False

        post_list = cmux_api._v2_request("workspace.list", {})
        new_workspace = next(
            (
                ws for ws in self._workspaces_from_result(post_list)
                if (ws.get("id") or ws.get("uuid")) not in existing_ids
            ),
            None,
        )
        if new_workspace is None:
            return None, False

        workspace_uuid = new_workspace.get("id") or new_workspace.get("uuid")
        cmux_api._v2_request(
            "workspace.rename",
            {"workspace_id": workspace_uuid, "title": title},
        )
        cmux_api._v2_request(
            "surface.send_text",
            {"workspace_id": workspace_uuid, "text": f"cd {cwd} && claude\n"},
        )
        self.mutex.set_cooldown(workspace_uuid, 5.0)
        return workspace_uuid, True

    def _wait_for_repl(self, ws_uuid, timeout_attempts=20, poll_interval=3.0):
        repl_ready = re.compile(r"(Model:|Cost:\s*\$\d|\u276f\s*$)", re.MULTILINE | re.IGNORECASE)
        for attempt in range(timeout_attempts):
            screen = cmux_api.cmux_read_workspace(0, 0, lines=30, workspace_uuid=ws_uuid) or ""
            if repl_ready.search(screen):
                return True
            if attempt < timeout_attempts - 1:
                time.sleep(poll_interval)
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
        launchable_tasks = [
            task for task in tasks
            if task.get("status") == "queued"
            and all(dep_id in completed for dep_id in task.get("dependsOn", []))
        ]

        if not launchable_tasks:
            return

        project_dir = objective.get("projectDir", "")
        base_branch = objective.get("baseBranch", "main")

        for task in launchable_tasks:
            if task.get("dependsOn"):
                self._assemble_context(objective_id, task)

            title_slug = worker.slugify(task.get("title", ""))
            branch_name = f"orchestrator/{task['id']}-{title_slug}" if title_slug else f"orchestrator/{task['id']}"
            worktree_path = worker.create_worktree(
                project_dir,
                objective_id,
                task["id"],
                title_slug,
                base_branch,
            )

            spec_content = objectives.read_task_file(objective_id, task["id"], "spec.md") or ""
            context_content = objectives.read_task_file(objective_id, task["id"], "context.md") or ""
            with open(os.path.join(worktree_path, "spec.md"), "w", encoding="utf-8") as f:
                f.write(spec_content)
            with open(os.path.join(worktree_path, "context.md"), "w", encoding="utf-8") as f:
                f.write(context_content)

            ws_uuid, created = self._create_worker_workspace(
                f"Worker: {task['title'][:35]}",
                worktree_path,
            )
            if not created or not ws_uuid:
                continue
            if not self._wait_for_repl(ws_uuid, timeout_attempts=10):
                continue
            if not cmux_api.send_prompt_to_workspace(ws_uuid, worker.build_task_prompt(task["id"])):
                continue

            task["status"] = "executing"
            task["workspaceId"] = ws_uuid
            task["worktreePath"] = worktree_path
            task["worktreeBranch"] = branch_name
            task["startedAt"] = _utc_now_iso()
            self._append_message(
                objective_id,
                "system",
                f"Task {task['id']}: {task['title']} — launched",
            )

        objectives.update_objective(objective_id, {"tasks": tasks})

    def poll_tasks(self, objective_id):
        objective = objectives.read_objective(objective_id)
        if objective is None:
            return

        for task in objective.get("tasks", []):
            if task.get("status") not in ("executing", "rework"):
                continue

            task_id = task["id"]
            ws_uuid = task.get("workspaceId")
            worktree_path = task.get("worktreePath")
            if not ws_uuid:
                continue

            screen_text = ""
            try:
                screen_text = cmux_api.cmux_read_workspace(
                    0, 0, lines=200, workspace_uuid=ws_uuid
                ) or ""
            except Exception:
                screen_text = ""

            prompt_info = None
            if screen_text:
                prompt_info = detection.detect_prompt(screen_text)

            prompt_detected = False
            if isinstance(prompt_info, dict):
                prompt_detected = prompt_info.get("type") != "none"
            elif prompt_info:
                prompt_detected = True

            if prompt_detected:
                spec_text = objectives.read_task_file(objective_id, task_id, "spec.md")
                classification = approval.classify_approval(screen_text, spec_text)
                if approval.should_auto_approve(classification):
                    with self.mutex.context(ws_uuid):
                        cmux_api.cmux_send_to_workspace(
                            0, 0, text="y\n", workspace_uuid=ws_uuid
                        )
                    self._append_message(
                        objective_id,
                        "system",
                        f"Task {task_id}: auto-approved ({classification.get('reason', 'routine')})",
                        metadata={"task_id": task_id, "classification": classification},
                    )
                else:
                    preview = screen_text[-500:] if len(screen_text) > 500 else screen_text
                    self._append_message(
                        objective_id,
                        "approval",
                        f"Task {task_id}: needs your input — {classification.get('reason', 'requires human judgment')}",
                        metadata={
                            "task_id": task_id,
                            "classification": classification,
                            "screen_preview": preview,
                        },
                    )

            last_ts = self._task_last_progress.get(task_id, 0)
            progress_state = monitor.check_progress(objective_id, task_id, last_ts)

            if progress_state.get("has_result"):
                has_claude = detection.detect_claude_session(screen_text) if screen_text else False
                if not has_claude:
                    task["status"] = "reviewing"
                    objectives.update_objective(objective_id, {"tasks": objective["tasks"]})
                    self._append_message(
                        objective_id,
                        "progress",
                        f"Task {task_id}: completed, starting review...",
                        metadata={"task_id": task_id},
                    )
                    if hasattr(self, "_run_review"):
                        threading.Thread(
                            target=self._run_review,
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
            elif stuck_status.get("level") == "amber":
                self._append_message(
                    objective_id,
                    "system",
                    f"Task {task_id}: terminal active but no progress updates ({stuck_status.get('elapsed_minutes', 0):.1f} min)",
                    metadata={"task_id": task_id, "stuck_status": stuck_status},
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
        return True
