from __future__ import annotations

import fnmatch
import os
import subprocess
from pathlib import Path


_SEARCH_EXCLUDED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".build",
    ".venv",
    "__pycache__",
    "build",
    "DerivedData",
    "dist",
    "node_modules",
    "venv",
}


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


def _xcode_target_for_root(root: Path) -> tuple[Path, str] | None:
    if root.suffix in {".xcworkspace", ".xcodeproj"} and root.exists():
        return root, root.suffix.removeprefix(".")

    for suffix, kind in (("*.xcworkspace", "xcworkspace"), ("*.xcodeproj", "xcodeproj")):
        matches = sorted(root.glob(suffix), key=lambda path: path.name.lower())
        if matches:
            return matches[0], kind

    package_file = root / "Package.swift"
    if package_file.is_file() and _package_mentions_ios(package_file):
        return package_file, "swift-package"

    return None


def _package_mentions_ios(package_file: Path) -> bool:
    try:
        contents = package_file.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return any(token in contents for token in (".iOS", "iOS(", "UIKit", "SwiftUI"))


def editor_targets_for_root(root: Path) -> dict:
    xcode_target = _xcode_target_for_root(root)
    xcode_data = {"available": False}
    if xcode_target is not None:
        target_path, target_type = xcode_target
        xcode_data = {
            "available": True,
            "targetPath": str(target_path),
            "targetType": target_type,
        }
    return {
        "vscode": {"available": True, "targetPath": str(root), "targetType": "directory"},
        "xcode": xcode_data,
    }


def _open_root_in_xcode(handler, root: Path):
    xcode_target = _xcode_target_for_root(root)
    if xcode_target is None:
        handler._json_response(
            {
                "ok": False,
                "error": "No Xcode workspace, project, or iOS Swift package found",
                "rootPath": str(root),
                "editor": "xcode",
            },
            404,
        )
        return

    target_path, target_type = xcode_target
    commands = [
        ["open", "-a", "Xcode", str(target_path)],
        ["xed", str(target_path)],
    ]
    last_error = None
    for command in commands:
        try:
            subprocess.run(command, check=True, capture_output=True, text=True)
            handler._json_response({
                "ok": True,
                "rootPath": str(root),
                "editor": "xcode",
                "targetPath": str(target_path),
                "targetType": target_type,
            })
            return
        except (OSError, subprocess.CalledProcessError) as exc:
            last_error = exc

    handler._json_response(
        {"ok": False, "error": str(last_error) if last_error else "Could not open root in Xcode"},
        500,
    )


def _open_root_in_editor(handler, root: Path, editor: str = "vscode"):
    normalized = str(editor or "vscode").strip().lower()
    if normalized in {"vscode", "vs-code", "code"}:
        _open_root_in_vscode(handler, root)
        return
    if normalized == "xcode":
        _open_root_in_xcode(handler, root)
        return
    handler._json_response({"ok": False, "error": "unsupported editor"}, 400)


def handle_open_worktree(handler, objective, editor: str = "vscode"):
    root = _objective_root(handler, objective)
    if root is None:
        return
    _open_root_in_editor(handler, root, editor)


def handle_open_root_path(handler, root_path: str, required_error: str, missing_label: str, editor: str = "vscode"):
    root_path = str(root_path or "").strip()
    if not root_path:
        handler._json_response({"ok": False, "error": required_error}, 400)
        return
    root = _existing_root(handler, root_path, missing_label)
    if root is None:
        return
    _open_root_in_editor(handler, root, editor)


def handle_open_workspace_root(handler, workspace, editor: str = "vscode"):
    handle_open_root_path(
        handler,
        workspace.get("rootPath"),
        "workspace rootPath required",
        "workspace root not found",
        editor,
    )


def _query_root(handler, parsed, *, engine) -> Path | None:
    params = handler.parse_qs(parsed.query)
    path_value = str(params.get("path", [""])[0] or "").strip()
    if path_value:
        return _existing_root(handler, path_value, "project root not found")

    index_value = str(params.get("index", [""])[0] or "").strip()
    if not index_value:
        handler._json_response({"ok": False, "error": "index or path required"}, 400)
        return None
    try:
        index = int(index_value)
    except (TypeError, ValueError):
        handler._json_response({"ok": False, "error": "invalid index"}, 400)
        return None

    cwd = engine._get_workspace_cwd(index)
    if not cwd:
        handler._json_response({"ok": False, "error": "workspace cwd not found"}, 404)
        return None
    return _existing_root(handler, cwd, "workspace cwd not found")


def _git_toplevel(root: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None
    value = (result.stdout or "").strip()
    if not value:
        return None
    candidate = Path(value).expanduser().resolve()
    if not candidate.is_dir():
        return None
    return candidate


def _project_root_for_search(root: Path) -> Path:
    return _git_toplevel(root) or root


def _project_root_for_skills(root: Path) -> Path:
    search_root = _git_toplevel(root) or root
    if search_root.parent.name == "worktrees" and search_root.parent.parent.name == ".claude":
        return search_root.parent.parent.parent
    return search_root


def handle_get_skills(handler, parsed, *, engine):
    root = _query_root(handler, parsed, engine=engine)
    if root is None:
        return

    project_root = _project_root_for_skills(root)
    project_skills = _collect_project_skills(project_root)
    user_skills = _collect_user_skills()

    handler._json_response({
        "ok": True,
        "rootPath": str(project_root),
        "skillsDirectory": ".claude/skills",
        "userSkillsDirectory": "~/.claude/skills",
        "projectSkills": project_skills,
        "userSkills": user_skills,
        "skills": project_skills + user_skills,
    })


def _collect_project_skills(project_root: Path) -> list[dict]:
    skills_dir = project_root / ".claude" / "skills"
    return _collect_skills(skills_dir, project_root=project_root, scope="project")


def _collect_user_skills() -> list[dict]:
    home = Path.home().expanduser().resolve()
    skills_dir = home / ".claude" / "skills"
    return _collect_skills(skills_dir, home=home, scope="user")


def _collect_skills(
    skills_dir: Path,
    *,
    scope: str,
    project_root: Path | None = None,
    home: Path | None = None,
) -> list[dict]:
    skills = []
    if not skills_dir.is_dir():
        return skills
    for item in sorted(skills_dir.iterdir(), key=lambda path: path.name.lower()):
        skill_file = item / "SKILL.md"
        if not item.is_dir() or not skill_file.is_file():
            continue
        if scope == "project" and project_root is not None:
            skill_file_path = skill_file.relative_to(project_root).as_posix()
        elif scope == "user" and home is not None:
            skill_file_path = "~/" + skill_file.relative_to(home).as_posix()
        else:
            skill_file_path = str(skill_file)
        skills.append({
            "name": item.name,
            "skillFilePath": skill_file_path,
            "scope": scope,
        })
    return skills


def handle_search_files(handler, parsed, *, engine):
    params = handler.parse_qs(parsed.query)
    query = str(params.get("q", params.get("query", [""]))[0] or "").strip()
    try:
        limit = int(str(params.get("limit", ["80"])[0] or "80"))
    except (TypeError, ValueError):
        limit = 80
    limit = max(1, min(limit, 500))

    root = _query_root(handler, parsed, engine=engine)
    if root is None:
        return

    project_root = _project_root_for_search(root)
    if len(query) < 3:
        handler._json_response({
            "ok": True,
            "rootPath": str(project_root),
            "query": query,
            "files": [],
            "truncated": False,
            "limit": limit,
        })
        return

    matching_paths = []
    query_key = query.casefold()
    for file_path in _iter_project_files(project_root):
        if query_key not in file_path.casefold():
            continue
        matching_paths.append({"path": file_path})
        if len(matching_paths) > limit:
            break

    truncated = len(matching_paths) > limit
    handler._json_response({
        "ok": True,
        "rootPath": str(project_root),
        "query": query,
        "files": matching_paths[:limit],
        "truncated": truncated,
        "limit": limit,
    })


def handle_resolve_dropped_files(handler, data):
    root_path = str(data.get("rootPath") or data.get("path") or "").strip()
    files = data.get("files")
    if not root_path:
        handler._json_response({"ok": False, "error": "rootPath required"}, 400)
        return
    if not isinstance(files, list) or not files:
        handler._json_response({"ok": False, "error": "files required"}, 400)
        return

    root = _existing_root(handler, root_path, "project root not found")
    if root is None:
        return

    project_root = _project_root_for_search(root)
    indexed_paths = _iter_project_files(project_root)
    resolved = []
    unresolved = []

    for file_data in files[:50]:
        if not isinstance(file_data, dict):
            continue
        match = _resolve_dropped_file(project_root, indexed_paths, file_data)
        if match is None:
            unresolved.append({"name": str(file_data.get("name") or "").strip(), "reason": "not found"})
        elif len(match) == 1:
            resolved.append(match[0])
        else:
            unresolved.append({
                "name": str(file_data.get("name") or "").strip(),
                "reason": "ambiguous",
                "matches": match[:20],
            })

    paths = [item["path"] for item in resolved]
    handler._json_response({
        "ok": True,
        "rootPath": str(project_root),
        "paths": paths,
        "resolved": resolved,
        "unresolved": unresolved,
    })


def _resolve_dropped_file(root: Path, indexed_paths: list[str], file_data: dict) -> list[dict] | None:
    name = Path(str(file_data.get("name") or "").strip()).name
    if not name:
        return None

    relative_path = str(file_data.get("relativePath") or "").replace("\\", "/").strip("/")
    if relative_path:
        candidate = _candidate_for_relative_drop(root, relative_path, file_data)
        if candidate is not None:
            return [candidate]

    matches = []
    for rel_path in indexed_paths:
        if Path(rel_path).name != name:
            continue
        candidate_path = root / rel_path
        if not candidate_path.is_file():
            continue
        if not _dropped_file_metadata_matches(candidate_path, file_data):
            continue
        matches.append({
            "path": str(candidate_path.resolve()),
            "relativePath": rel_path,
        })

    if not matches:
        return None
    return matches


def _candidate_for_relative_drop(root: Path, relative_path: str, file_data: dict) -> dict | None:
    candidate_path = (root / relative_path).resolve()
    try:
        if os.path.commonpath([str(root), str(candidate_path)]) != str(root):
            return None
    except ValueError:
        return None
    if not candidate_path.is_file():
        return None
    if not _dropped_file_metadata_matches(candidate_path, file_data):
        return None
    return {
        "path": str(candidate_path),
        "relativePath": relative_path,
    }


def _dropped_file_metadata_matches(path: Path, file_data: dict) -> bool:
    try:
        stat = path.stat()
    except OSError:
        return False

    size = file_data.get("size")
    if isinstance(size, (int, float)) and size >= 0 and int(size) != stat.st_size:
        return False

    last_modified = file_data.get("lastModified")
    if isinstance(last_modified, (int, float)) and last_modified > 0:
        modified_ms = stat.st_mtime * 1000
        if abs(modified_ms - float(last_modified)) > 2000:
            return False

    return True


def _iter_project_files(root: Path) -> list[str]:
    git_files = _git_list_files(root)
    if git_files is not None:
        return git_files
    return _walk_project_files(root)


def _git_list_files(root: Path) -> list[str] | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None
    paths = {
        path.replace("\\", "/")
        for path in (result.stdout or "").split("\0")
        if path and not path.startswith("../") and not os.path.isabs(path)
    }
    return sorted(paths, key=lambda value: value.casefold())


def _walk_project_files(root: Path) -> list[str]:
    ignore_patterns = _read_gitignore_patterns(root)
    paths = []
    for current_root, dirs, files in os.walk(root):
        current = Path(current_root)
        relative_dir = current.relative_to(root).as_posix()
        dirs[:] = [
            dirname for dirname in dirs
            if not _is_ignored_dir(dirname, relative_dir, ignore_patterns)
        ]
        for filename in files:
            rel = (current / filename).relative_to(root).as_posix()
            if _matches_gitignore(rel, filename, ignore_patterns):
                continue
            paths.append(rel)
    return sorted(paths, key=lambda value: value.casefold())


def _read_gitignore_patterns(root: Path) -> list[str]:
    gitignore = root / ".gitignore"
    try:
        lines = gitignore.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    patterns = []
    for line in lines:
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        patterns.append(value)
    return patterns


def _is_ignored_dir(dirname: str, relative_dir: str, patterns: list[str]) -> bool:
    if dirname in _SEARCH_EXCLUDED_DIRS:
        return True
    rel = dirname if relative_dir == "." else f"{relative_dir}/{dirname}"
    return _matches_gitignore(rel + "/", dirname, patterns)


def _matches_gitignore(path: str, basename: str, patterns: list[str]) -> bool:
    normalized = path.strip("/")
    for pattern in patterns:
        negated = pattern.startswith("!")
        raw_pattern = pattern[1:] if negated else pattern
        raw_pattern = raw_pattern.strip()
        if not raw_pattern:
            continue
        directory_only = raw_pattern.endswith("/")
        candidate_pattern = raw_pattern.strip("/")
        if not candidate_pattern:
            continue

        matched = False
        if "/" in candidate_pattern:
            matched = fnmatch.fnmatch(normalized, candidate_pattern)
            if directory_only:
                matched = matched or normalized.startswith(candidate_pattern + "/")
        else:
            matched = fnmatch.fnmatch(basename, candidate_pattern)
            if directory_only:
                matched = basename == candidate_pattern

        if matched:
            return not negated
    return False
