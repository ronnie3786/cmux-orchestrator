from __future__ import annotations

from collections import deque
from pathlib import Path


def _handle_get_console_logs(handler, root_path: str, parsed, *, re_module, human_file_size, missing_error: str):
    params = handler.parse_qs(parsed.query)
    try:
        line_limit = int(params.get("lines", ["500"])[0])
    except (TypeError, ValueError):
        line_limit = 500
    line_limit = max(1, min(line_limit, 2000))
    filter_pattern = str(params.get("filter", [""])[0] or "").strip()
    requested_file = str(params.get("file", [""])[0] or "").strip()
    if requested_file:
        if (
            not requested_file.endswith(".log")
            or "/" in requested_file
            or "\\" in requested_file
            or ".." in requested_file
        ):
            handler._json_response({"ok": False, "error": "invalid file"}, 400)
            return
    matcher = None
    if filter_pattern:
        try:
            matcher = re_module.compile(filter_pattern, re_module.IGNORECASE)
        except re_module.error as exc:
            handler._json_response({"ok": False, "error": f"invalid regex: {exc}"}, 400)
            return
    if not root_path:
        handler._json_response({"ok": False, "error": missing_error}, 400)
        return
    logs_dir = Path(root_path) / ".build" / "logs"
    try:
        files = sorted(
            entry.name for entry in logs_dir.glob("*.log")
            if entry.is_file()
        ) if logs_dir.exists() and logs_dir.is_dir() else []
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return
    if not files:
        handler._json_response({
            "exists": False,
            "files": [],
            "activeFile": "",
            "lines": [],
            "totalLines": 0,
            "matchedLines": 0,
            "fileSize": 0,
            "fileSizeHuman": "0 B",
            "truncated": False,
            "filter": filter_pattern,
        })
        return
    active_file = requested_file or files[0]
    if active_file not in files:
        handler._json_response({"ok": False, "error": "invalid file"}, 400)
        return
    log_path = logs_dir / active_file
    try:
        file_size = log_path.stat().st_size
        total_lines = 0
        matched_lines = 0
        tail = deque(maxlen=line_limit)
        with log_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                total_lines += 1
                cleaned = line.rstrip("\r\n")
                if matcher is not None:
                    if not matcher.search(cleaned):
                        continue
                    matched_lines += 1
                else:
                    matched_lines = total_lines
                tail.append(cleaned)
        lines = list(tail)
        truncated = matched_lines > len(lines)
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return
    handler._json_response({
        "exists": True,
        "files": files,
        "activeFile": active_file,
        "lines": lines,
        "totalLines": total_lines,
        "matchedLines": matched_lines,
        "fileSize": file_size,
        "fileSizeHuman": human_file_size(file_size),
        "truncated": truncated,
        "filter": filter_pattern,
    })


def handle_get_console_logs(handler, objective, parsed, *, re_module, human_file_size):
    root_path = str(objective.get("worktreePath") or "").strip()
    _handle_get_console_logs(
        handler,
        root_path,
        parsed,
        re_module=re_module,
        human_file_size=human_file_size,
        missing_error="objective worktreePath required",
    )


def handle_get_console_logs_for_root(
    handler,
    root_path: str,
    parsed,
    *,
    re_module,
    human_file_size,
    missing_error: str = "rootPath required",
):
    _handle_get_console_logs(
        handler,
        str(root_path or "").strip(),
        parsed,
        re_module=re_module,
        human_file_size=human_file_size,
        missing_error=missing_error,
    )


def handle_get_workspace_console_logs(handler, workspace, parsed, *, re_module, human_file_size):
    root_path = str(workspace.get("rootPath") or "").strip()
    _handle_get_console_logs(
        handler,
        root_path,
        parsed,
        re_module=re_module,
        human_file_size=human_file_size,
        missing_error="workspace rootPath required",
    )
