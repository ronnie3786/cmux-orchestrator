from __future__ import annotations

from collections import deque
from pathlib import Path


def _handle_get_build_log(handler, root_path: str, parsed, *, human_file_size, missing_error: str):
    params = handler.parse_qs(parsed.query)
    try:
        line_limit = int(params.get("lines", ["200"])[0])
    except (TypeError, ValueError):
        line_limit = 200
    try:
        offset = int(params.get("offset", ["0"])[0])
    except (TypeError, ValueError):
        offset = 0
    filename = str(params.get("file", ["build.log"])[0] or "build.log").strip()
    if filename not in {"build.log", "prebuild.log"}:
        handler._json_response({"ok": False, "error": "invalid file"}, 400)
        return
    line_limit = max(1, min(line_limit, 1000))
    offset = max(0, offset)
    if not root_path:
        handler._json_response({"ok": False, "error": missing_error}, 400)
        return
    log_path = Path(root_path) / ".build" / filename
    try:
        log_exists = log_path.exists()
        log_is_file = log_path.is_file() if log_exists else False
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return
    if not log_exists or not log_is_file:
        handler._json_response({
            "exists": False,
            "lines": [],
            "fileSize": 0,
            "fileSizeHuman": "0 B",
            "totalLines": 0,
            "truncated": False,
        })
        return
    try:
        file_size = log_path.stat().st_size
        if offset > 0:
            total_lines = 0
            lines = []
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    total_lines += 1
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(min(offset, file_size))
                for line in handle:
                    lines.append(line.rstrip("\r\n"))
            truncated = False
        else:
            total_lines = 0
            tail = deque(maxlen=line_limit)
            with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    total_lines += 1
                    tail.append(line.rstrip("\r\n"))
            lines = list(tail)
            truncated = total_lines > len(lines)
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return
    handler._json_response({
        "exists": True,
        "lines": lines,
        "fileSize": file_size,
        "fileSizeHuman": human_file_size(file_size),
        "totalLines": total_lines,
        "truncated": truncated,
    })


def handle_get_build_log(handler, objective, parsed, *, human_file_size):
    root_path = str(objective.get("worktreePath") or "").strip()
    _handle_get_build_log(
        handler,
        root_path,
        parsed,
        human_file_size=human_file_size,
        missing_error="objective worktreePath required",
    )


def handle_get_build_log_for_root(
    handler,
    root_path: str,
    parsed,
    *,
    human_file_size,
    missing_error: str = "rootPath required",
):
    _handle_get_build_log(
        handler,
        str(root_path or "").strip(),
        parsed,
        human_file_size=human_file_size,
        missing_error=missing_error,
    )


def handle_get_workspace_build_log(handler, workspace, parsed, *, human_file_size):
    root_path = str(workspace.get("rootPath") or "").strip()
    _handle_get_build_log(
        handler,
        root_path,
        parsed,
        human_file_size=human_file_size,
        missing_error="workspace rootPath required",
    )
