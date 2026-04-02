from __future__ import annotations

import re
import subprocess
from pathlib import Path

from .objectives import get_objective_dir


class WorkerError(Exception):
    pass


def slugify(text: str, max_len: int = 30) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower())
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug[:max_len].rstrip("-")


def create_worktree(
    project_dir: str,
    objective_id: str,
    task_id: str,
    task_slug: str,
    base_branch: str = "main",
) -> str:
    branch_slug = slugify(task_slug)
    branch_name = f"orchestrator/{task_id}-{branch_slug}" if branch_slug else f"orchestrator/{task_id}"
    worktree_path = get_objective_dir(objective_id) / "tasks" / task_id / "worktree"
    worktree_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            [
                "git",
                "-C",
                project_dir,
                "worktree",
                "add",
                str(worktree_path),
                "-b",
                branch_name,
                base_branch,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        message = stderr or stdout or f"git worktree add failed with exit code {exc.returncode}"
        raise WorkerError(message) from exc
    except OSError as exc:
        raise WorkerError(str(exc)) from exc
    return str(worktree_path)


def remove_worktree(project_dir: str, worktree_path: str):
    try:
        subprocess.run(
            ["git", "-C", project_dir, "worktree", "remove", worktree_path, "--force"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        return


def build_task_prompt(task_id: str) -> str:
    return f"""You have a specific task to complete: {task_id}

Read ./spec.md for your full task description.
Read ./context.md for relevant context from prior completed tasks (if it exists).

IMPORTANT - Progress tracking:
As you work, update ./progress.md after completing each major step.
Use this format:

## Checkpoint: [name]
**Status:** Done
**What I did:** [2-3 sentence summary]
**Files touched:** [list]

This lets the orchestrator track your progress. Update progress.md
BEFORE moving to the next checkpoint, not all at the end.

IMPORTANT: Update progress.md NOW before proceeding.

When you are completely finished with everything in spec.md:
1. Commit all changes to your branch.
2. Write a final summary to ./result.md covering:
   - What was accomplished
   - Files changed and why
   - Any issues encountered
   - Suggestions for follow-up work
3. Then exit.
"""


def build_rework_prompt(issues: list[str], recommendation: str) -> str:
    issue_lines = "\n".join(f"{index}. {issue}" for index, issue in enumerate(issues, start=1))
    return f"""Your previous work was reviewed and the following issues were found:

{issue_lines}

Reviewer's recommendation: {recommendation}

Please address ALL of these issues. Your original task spec is in ./spec.md
and your previous progress is in ./progress.md.

After fixing, add a new "Rework" checkpoint to ./progress.md and
write an updated ./result.md covering what you changed.
"""
