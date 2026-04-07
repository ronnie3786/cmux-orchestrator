from __future__ import annotations

import subprocess
from pathlib import Path

def _objective_root(handler, objective) -> Path | None:
    worktree_path = str(objective.get("worktreePath") or "").strip()
    if not worktree_path:
        handler._json_response({"ok": False, "error": "objective worktreePath required"}, 400)
        return None
    root = Path(worktree_path).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        handler._json_response({"ok": False, "error": "objective worktree not found"}, 404)
        return None
    return root

def handle_open_worktree(handler, objective):
    root = _objective_root(handler, objective)
    if root is None:
        return

    commands = [
        ["open", "-a", "Visual Studio Code", str(root)],
        ["code", str(root)],
    ]
    last_error = None
    for command in commands:
        try:
            subprocess.run(command, check=True, capture_output=True, text=True)
            handler._json_response({"ok": True, "rootPath": str(root), "editor": "vscode"})
            return
        except (OSError, subprocess.CalledProcessError) as exc:
            last_error = exc

    handler._json_response(
        {"ok": False, "error": str(last_error) if last_error else "Could not open worktree in VS Code"},
        500,
    )
