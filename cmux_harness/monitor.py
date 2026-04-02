from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from datetime import datetime, timezone

from .objectives import get_objective_dir, read_task_file


CHECKPOINT_HEADER_RE = re.compile(
    r"^\s*##\s*Checkpoint\s*:\s*(?P<name>.+?)\s*$",
    re.IGNORECASE | re.MULTILINE,
)


def _extract_field(block: str, label: str) -> str:
    pattern = re.compile(
        rf"^\s*\*{{0,2}}\s*{re.escape(label)}\s*:\s*\*{{0,2}}\s*(?P<value>.+?)\s*$",
        re.IGNORECASE | re.MULTILINE,
    )
    match = pattern.search(block)
    if not match:
        return ""
    return match.group("value").strip()


def parse_checkpoints(progress_text: str) -> list[dict]:
    if not progress_text or not progress_text.strip():
        return []

    matches = list(CHECKPOINT_HEADER_RE.finditer(progress_text))
    checkpoints = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(progress_text)
        block = progress_text[start:end]
        checkpoints.append(
            {
                "name": match.group("name").strip(),
                "status": _extract_field(block, "Status"),
                "summary": _extract_field(block, "What I did"),
                "files": _extract_field(block, "Files touched"),
            }
        )
    return checkpoints


def check_progress(objective_id: str, task_id: str, last_check_ts: float, worktree_path: str = None) -> dict:
    task_dir = get_objective_dir(objective_id) / "tasks" / task_id
    progress_path = task_dir / "progress.md"
    progress_text = read_task_file(objective_id, task_id, "progress.md") or ""
    result_text = read_task_file(objective_id, task_id, "result.md") or ""

    # Also check worktree for result.md (workers write there, not task dir)
    if not result_text.strip() and worktree_path:
        wt_result = Path(worktree_path) / "result.md"
        if wt_result.is_file():
            result_text = wt_result.read_text(encoding="utf-8", errors="replace")
            # Copy to task dir so downstream consumers find it
            try:
                (task_dir / "result.md").write_text(result_text, encoding="utf-8")
            except OSError:
                pass

    progress_mtime = None
    try:
        progress_mtime = os.path.getmtime(progress_path)
    except OSError:
        pass

    checkpoints = parse_checkpoints(progress_text)
    return {
        "has_progress_update": progress_mtime is not None and progress_mtime > last_check_ts,
        "has_result": bool(result_text.strip()),
        "checkpoint_count": len(checkpoints),
        "checkpoints": checkpoints,
        "progress_mtime": progress_mtime,
    }


def check_git_activity(worktree_path: str, since_timestamp: float) -> bool:
    since_iso = datetime.fromtimestamp(since_timestamp, tz=timezone.utc).isoformat()
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                worktree_path,
                "log",
                "--oneline",
                f"--since={since_iso}",
                "--no-merges",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError, ValueError):
        return False
    return bool((result.stdout or "").strip())


def assess_stuck_status(task_state: dict) -> dict:
    status = task_state.get("status")
    last_progress_at = task_state.get("last_progress_at")
    now = task_state.get("now")

    if status != "executing" or last_progress_at is None or now is None:
        return {
            "level": "ok",
            "reason": "Task is not currently eligible for stuck detection",
            "elapsed_minutes": 0.0,
        }

    elapsed_minutes = max(0.0, (float(now) - float(last_progress_at)) / 60.0)
    if elapsed_minutes < 5:
        return {
            "level": "ok",
            "reason": "Recent progress update detected",
            "elapsed_minutes": elapsed_minutes,
        }
    if elapsed_minutes < 7:
        return {
            "level": "monitoring",
            "reason": "No recent progress update; begin secondary checks",
            "elapsed_minutes": elapsed_minutes,
        }
    if task_state.get("has_git_activity"):
        return {
            "level": "ok",
            "reason": "Git activity detected since the last progress update",
            "elapsed_minutes": elapsed_minutes,
        }
    if task_state.get("has_terminal_activity"):
        return {
            "level": "amber",
            "reason": "Terminal activity detected without progress updates or commits",
            "elapsed_minutes": elapsed_minutes,
        }
    return {
        "level": "stalled",
        "reason": "No progress updates, git activity, or terminal changes detected",
        "elapsed_minutes": elapsed_minutes,
    }


def should_trigger_rework(review_json: dict) -> bool:
    if not isinstance(review_json, dict) or not review_json:
        return False
    issues = review_json.get("issues")
    if isinstance(issues, list) and any(str(issue).strip() for issue in issues):
        return True
    if review_json.get("confidence") == "low":
        return True
    if review_json.get("readyForPR") is False:
        return True
    return False


def build_review_rework_summary(review_json: dict) -> tuple[list[str], str]:
    raw_issues = review_json.get("issues") if isinstance(review_json, dict) else None
    issues = []
    if isinstance(raw_issues, list):
        issues = [str(issue).strip() for issue in raw_issues if str(issue).strip()]
    if not issues:
        issues = ["Review flagged concerns but no specific issues listed"]

    recommendation = "Address the identified issues"
    if isinstance(review_json, dict):
        recommendation = review_json.get("recommendation", recommendation) or recommendation
    return issues, recommendation


def can_retry_review(task: dict) -> bool:
    review_cycles = task.get("reviewCycles", 0)
    max_review_cycles = task.get("maxReviewCycles", 5)
    return review_cycles < max_review_cycles
