from __future__ import annotations

import subprocess
from pathlib import Path

def _existing_root(handler, root_path: str, missing_label: str) -> Path | None:
    root = Path(root_path).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        handler._json_response({"ok": False, "error": missing_label}, 404)
        return None
    return root

def _objective_root(handler, objective) -> Path | None:
    worktree_path = str(objective.get("worktreePath") or "").strip()
    if not worktree_path:
        handler._json_response({"ok": False, "error": "objective worktreePath required"}, 400)
        return None
    return _existing_root(handler, worktree_path, "objective worktree not found")

def _open_root_in_vscode(handler, root: Path):
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
        {"ok": False, "error": str(last_error) if last_error else "Could not open root in VS Code"},
        500,
    )


def handle_open_worktree(handler, objective):
    root = _objective_root(handler, objective)
    if root is None:
        return
    _open_root_in_vscode(handler, root)


def handle_open_root_path(handler, root_path: str, required_error: str, missing_label: str):
    root_path = str(root_path or "").strip()
    if not root_path:
        handler._json_response({"ok": False, "error": required_error}, 400)
        return
    root = _existing_root(handler, root_path, missing_label)
    if root is None:
        return
    _open_root_in_vscode(handler, root)


def handle_open_workspace_root(handler, workspace):
    handle_open_root_path(
        handler,
        workspace.get("rootPath"),
        "workspace rootPath required",
        "workspace root not found",
    )
