from __future__ import annotations

import os
import subprocess
from pathlib import Path

_MAX_LIST_ITEMS = 5000
_MAX_PREVIEW_BYTES = 128 * 1024
_SKIP_DIRS = {".git"}
_FILE_INDEX_CACHE: dict[str, dict] = {}


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


def _resolve_relative_file(handler, root: Path, rel_path: str | None) -> Path | None:
    normalized = str(rel_path or "").strip().replace("\\", "/")
    if not normalized:
        handler._json_response({"ok": False, "error": "file path required"}, 400)
        return None
    candidate = (root / normalized).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        handler._json_response({"ok": False, "error": "path outside objective worktree"}, 400)
        return None
    if not candidate.exists() or not candidate.is_file():
        handler._json_response({"ok": False, "error": "file not found"}, 404)
        return None
    return candidate


def _looks_like_text(raw: bytes) -> bool:
    if not raw:
        return True
    if b"\x00" in raw:
        return False
    control_count = sum(1 for byte in raw if byte < 9 or (13 < byte < 32))
    if control_count > max(8, len(raw) // 20):
        return False
    try:
        raw.decode("utf-8")
        return True
    except UnicodeDecodeError:
        decoded = raw.decode("utf-8", errors="replace")
        replacement_count = decoded.count("\ufffd")
        return replacement_count <= max(6, len(decoded) // 40)


def _root_signature(root: Path) -> tuple[int, int]:
    stat = root.stat()
    return (int(stat.st_mtime_ns), int(stat.st_ino))


def _build_file_index(root: Path, *, human_file_size):
    items = []
    truncated = False
    for current_root, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(name for name in dirnames if name not in _SKIP_DIRS)
        for filename in sorted(filenames):
            full_path = Path(current_root) / filename
            rel_path = full_path.relative_to(root).as_posix()
            try:
                stat = full_path.stat()
            except OSError:
                continue
            items.append({
                "name": filename,
                "nameLower": filename.lower(),
                "path": rel_path,
                "pathLower": rel_path.lower(),
                "absolutePath": str(full_path),
                "directory": str(Path(rel_path).parent.as_posix()) if Path(rel_path).parent.as_posix() != "." else "",
                "size": stat.st_size,
                "sizeHuman": human_file_size(stat.st_size),
                "extension": full_path.suffix.lower(),
            })
            if len(items) >= _MAX_LIST_ITEMS:
                truncated = True
                break
        if truncated:
            break
    return {"items": items, "truncated": truncated}


def _get_cached_file_index(root: Path, *, human_file_size):
    key = str(root)
    signature = _root_signature(root)
    cached = _FILE_INDEX_CACHE.get(key)
    if cached and cached.get("signature") == signature:
        return cached["payload"]
    payload = _build_file_index(root, human_file_size=human_file_size)
    _FILE_INDEX_CACHE[key] = {"signature": signature, "payload": payload}
    return payload


def handle_list_files(handler, objective, parsed, *, human_file_size):
    root = _objective_root(handler, objective)
    if root is None:
        return
    params = handler.parse_qs(parsed.query)
    query = str(params.get("query", [""])[0] or "").strip()
    query_lower = query.lower()
    indexed = _get_cached_file_index(root, human_file_size=human_file_size)
    all_items = indexed["items"]
    truncated = indexed["truncated"]

    if query_lower:
        items = [
            {
                "name": item["name"],
                "path": item["path"],
                "absolutePath": item["absolutePath"],
                "directory": item["directory"],
                "size": item["size"],
                "sizeHuman": item["sizeHuman"],
                "extension": item["extension"],
            }
            for item in all_items
            if query_lower in item["pathLower"] or query_lower in item["nameLower"]
        ]
    else:
        items = [
            {
                "name": item["name"],
                "path": item["path"],
                "absolutePath": item["absolutePath"],
                "directory": item["directory"],
                "size": item["size"],
                "sizeHuman": item["sizeHuman"],
                "extension": item["extension"],
            }
            for item in all_items
        ]

    handler._json_response({
        "ok": True,
        "rootPath": str(root),
        "query": query,
        "items": items,
        "count": len(items),
        "truncated": truncated,
    })


def handle_get_file_preview(handler, objective, parsed, *, human_file_size):
    root = _objective_root(handler, objective)
    if root is None:
        return
    params = handler.parse_qs(parsed.query)
    file_path = _resolve_relative_file(handler, root, params.get("path", [""])[0])
    if file_path is None:
        return

    try:
        file_size = file_path.stat().st_size
        with file_path.open("rb") as handle:
            raw = handle.read(_MAX_PREVIEW_BYTES + 1)
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
        return

    preview_bytes = raw[:_MAX_PREVIEW_BYTES]
    truncated = file_size > _MAX_PREVIEW_BYTES
    rel_path = file_path.relative_to(root).as_posix()

    if not _looks_like_text(preview_bytes):
        handler._json_response({
            "ok": True,
            "path": rel_path,
            "absolutePath": str(file_path),
            "previewable": False,
            "binary": True,
            "reason": "Binary or unsupported file type",
            "size": file_size,
            "sizeHuman": human_file_size(file_size),
            "truncated": False,
            "content": "",
        })
        return

    content = preview_bytes.decode("utf-8", errors="replace")
    handler._json_response({
        "ok": True,
        "path": rel_path,
        "absolutePath": str(file_path),
        "previewable": True,
        "binary": False,
        "reason": "",
        "size": file_size,
        "sizeHuman": human_file_size(file_size),
        "truncated": truncated,
        "content": content,
    })


def handle_open_file(handler, objective, data):
    root = _objective_root(handler, objective)
    if root is None:
        return
    file_path = _resolve_relative_file(handler, root, data.get("path"))
    if file_path is None:
        return
    try:
        subprocess.Popen(["open", str(file_path)])
        handler._json_response({"ok": True})
    except OSError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 500)
