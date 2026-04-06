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

Read ./spec.md CAREFULLY — it defines your EXACT scope.

CRITICAL RULES:
- Implement the deliverables described in spec.md. Focus on the user story.
- Do NOT install packages, modify configs, or touch files outside your scope
- Do NOT implement anything beyond what spec.md describes
- If something seems needed but isn't in scope, note it in result.md — don't do it

Read ./context.md for relevant context from prior completed tasks (if it exists).

PROGRESS TRACKING — update ./progress.md after EACH checkpoint:

## Checkpoint: [name]
**Status:** Done
**What I did:** [2-3 sentence summary]
**Files touched:** [list of files changed]

Update progress.md BEFORE moving to the next checkpoint.

WHEN FINISHED with all checkpoints in spec.md:
1. Run `git diff --stat` and verify the changes align with the deliverables in spec.md
2. If you accidentally changed unrelated files, revert them with `git checkout`
3. Commit all in-scope changes to your branch
4. Write ./result.md covering:
   - What was accomplished (match to spec checkpoints)
   - Files changed
   - Any out-of-scope work that SHOULD be done (as suggestions only)
5. Then exit.
"""


def build_rework_prompt(issues: list[str], recommendation: str) -> str:
    issue_lines = "\n".join(f"{index}. {issue}" for index, issue in enumerate(issues, start=1))
    return f"""Your previous work was reviewed and needs fixes.

ISSUES FOUND:
{issue_lines}

Reviewer's recommendation: {recommendation}

RULES (same as before — re-read ./spec.md):
- Implement the deliverables described in spec.md. Focus on the user story.
- Do NOT expand scope to fix issues beyond the assigned deliverables
- If an issue can't be fixed within scope, note it in result.md as a limitation

Re-read ./spec.md for the user story and deliverables.
Check ./progress.md for what you already did.

After fixing:
1. Run `git diff --stat` and verify the changes match the deliverables
2. Revert any unrelated changes with `git checkout`
3. Commit in-scope changes
4. Add a "Rework" checkpoint to ./progress.md
5. Write updated ./result.md
6. Exit
"""
