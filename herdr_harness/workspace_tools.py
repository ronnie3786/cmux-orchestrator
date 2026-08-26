"""Workspace-scoped Git, file, skill, and Jira helpers for Herdr Harness.

The HTTP API never accepts a filesystem root for these operations.  Callers
must first resolve a cached Herdr workspace and pass its server-side path into
the helpers below.
"""

from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping, Optional


GIT_TIMEOUT_SECONDS = 10
JIRA_TIMEOUT_SECONDS = 15
MAX_DIFF_BYTES = 64 * 1024
MAX_FILE_RESULTS = 500
_SEARCH_EXCLUDED_DIRS = frozenset(
    {
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
)
_PROJECT_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
_JIRA_KEY_RE = re.compile(r"\b([A-Z][A-Z0-9_]+-\d+)\b", re.IGNORECASE)


class WorkspaceToolError(RuntimeError):
    """Expected tooling failure with an HTTP-safe status and error code."""

    def __init__(self, message: str, *, code: str = "workspace_tool_error", status: int = 500):
        super().__init__(message)
        self.code = code
        self.status = status


def workspace_root(workspace: dict) -> Optional[Path]:
    """Resolve a workspace root only from fields in the cached Herdr record."""

    candidates: list[Any] = []
    worktree = workspace.get("worktree")
    if isinstance(worktree, dict):
        candidates.append(worktree.get("checkout_path"))

    panes = workspace.get("panes")
    if isinstance(panes, list):
        ordered_panes = sorted(
            (pane for pane in panes if isinstance(pane, dict)),
            key=lambda pane: not bool(pane.get("focused")),
        )
        for pane in ordered_panes:
            candidates.extend((pane.get("foreground_cwd"), pane.get("cwd")))

    for value in candidates:
        if not isinstance(value, str) or not value.strip() or "\x00" in value:
            continue
        try:
            candidate = Path(value).expanduser().resolve()
        except (OSError, RuntimeError):
            continue
        if candidate.is_dir():
            return candidate
    return None


def _run(
    command: list[str],
    *,
    cwd: Optional[Path] = None,
    timeout: int = GIT_TIMEOUT_SECONDS,
    accepted_codes: tuple[int, ...] = (0,),
    maximum_bytes: Optional[int] = None,
) -> tuple[str, bool]:
    try:
        if maximum_bytes is None:
            result = subprocess.run(
                command,
                cwd=str(cwd) if cwd is not None else None,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
            output = result.stdout or ""
            error_output = result.stderr or ""
            truncated = False
        else:
            # Git diffs can be arbitrarily large.  Write both streams directly
            # to anonymous temporary files so subprocess never accumulates the
            # complete output in memory, then read only the response budget.
            with tempfile.TemporaryFile(mode="w+b") as stdout_file, tempfile.TemporaryFile(
                mode="w+b"
            ) as stderr_file:
                result = subprocess.run(
                    command,
                    cwd=str(cwd) if cwd is not None else None,
                    stdout=stdout_file,
                    stderr=stderr_file,
                    timeout=timeout,
                    check=False,
                )
                stdout_file.seek(0)
                encoded = stdout_file.read(maximum_bytes + 1)
                truncated = len(encoded) > maximum_bytes
                if truncated:
                    marker = b"\n...[truncated]..."
                    available = max(0, maximum_bytes - len(marker))
                    encoded = encoded[:available] + marker
                output = encoded.decode("utf-8", errors="replace")
                stderr_file.seek(0)
                error_output = stderr_file.read(8 * 1024).decode("utf-8", errors="replace")
    except FileNotFoundError as exc:
        raise WorkspaceToolError(
            f"{command[0]} is not installed or is not on PATH",
            code=f"{command[0]}_unavailable",
            status=503,
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise WorkspaceToolError(
            f"{command[0]} command timed out",
            code=f"{command[0]}_timeout",
            status=504,
        ) from exc
    except OSError as exc:
        raise WorkspaceToolError(
            f"Could not run {command[0]}: {exc}",
            code=f"{command[0]}_failed",
            status=502,
        ) from exc

    if result.returncode not in accepted_codes:
        message = (error_output or output or f"{command[0]} command failed").strip()
        raise WorkspaceToolError(
            _clean_external_text(message, maximum=2_000),
            code=f"{command[0]}_failed",
            status=422,
        )

    return output, truncated


def _git(root: Path, args: list[str], **kwargs: Any) -> tuple[str, bool]:
    return _run(["git", "-C", str(root), *args], **kwargs)


def git_root(root: Path) -> Path:
    try:
        output, _ = _git(root, ["rev-parse", "--show-toplevel"])
    except WorkspaceToolError as exc:
        if exc.code != "git_failed":
            raise
        raise WorkspaceToolError(
            "Workspace is not inside a Git repository",
            code="git_repository_not_found",
            status=404,
        ) from exc
    value = output.strip()
    if not value:
        raise WorkspaceToolError(
            "Workspace is not inside a Git repository",
            code="git_repository_not_found",
            status=404,
        )
    try:
        candidate = Path(value).expanduser().resolve()
    except (OSError, RuntimeError) as exc:
        raise WorkspaceToolError(
            "Git returned an invalid repository path",
            code="git_repository_invalid",
            status=502,
        ) from exc
    if not candidate.is_dir():
        raise WorkspaceToolError(
            "Git repository root is unavailable",
            code="git_repository_not_found",
            status=404,
        )
    return candidate


def _project_root(root: Path) -> Path:
    """Use the active Git checkout when available, otherwise the cached root."""

    try:
        return git_root(root)
    except WorkspaceToolError as exc:
        if exc.code != "git_repository_not_found":
            raise
        return root.resolve()


def _skills_project_root(root: Path) -> Path:
    """Map Claude-managed worktrees to their parent project's shared skills."""

    project_root = _project_root(root)

    if (
        project_root.parent.name == "worktrees"
        and project_root.parent.parent.name == ".claude"
    ):
        parent_project = project_root.parent.parent.parent
        if parent_project.is_dir():
            return parent_project.resolve()
    return project_root


def _porcelain_entries(raw: str) -> tuple[list[dict], list[dict], list[str]]:
    staged: list[dict] = []
    unstaged: list[dict] = []
    untracked: list[str] = []
    records = raw.split("\0")
    index = 0
    while index < len(records):
        record = records[index]
        index += 1
        if len(record) < 4:
            continue
        x, y, path = record[0], record[1], record[3:]
        # In porcelain v1 -z output a rename/copy record is followed by its
        # source path.  The first path is the destination and is the useful
        # pathspec for staging, diffing, and display.
        if x in {"R", "C"} or y in {"R", "C"}:
            index += 1
        if x == "?" and y == "?":
            untracked.append(path)
            continue
        if x not in {" ", "?", "!"}:
            staged.append({"status": x, "file": path})
        if y not in {" ", "?", "!"}:
            unstaged.append({"status": y, "file": path})
    return staged, unstaged, untracked


def git_status(root: Path) -> dict:
    repository = git_root(root)
    raw, _ = _git(
        repository,
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )
    staged, unstaged, untracked = _porcelain_entries(raw)

    try:
        branch, _ = _git(repository, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        branch_name = branch.strip()
    except WorkspaceToolError:
        branch_name = "HEAD"

    try:
        log, _ = _git(repository, ["log", "-10", "--format=%h%x1f%s%x1e"])
        commits = []
        for record in log.split("\x1e"):
            value = record.strip("\r\n")
            if "\x1f" not in value:
                continue
            commit_hash, message = value.split("\x1f", 1)
            if commit_hash and message:
                commits.append({"hash": commit_hash, "message": message})
    except WorkspaceToolError:
        commits = []

    return {
        "root_path": str(repository),
        "branch": branch_name,
        "staged": staged,
        "unstaged": unstaged,
        "untracked": untracked,
        "commits": commits,
    }


def _relative_git_path(repository: Path, value: Any) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value) > 4096:
        raise WorkspaceToolError("file is required", code="invalid_git_path", status=400)
    candidate_path = Path(value)
    if candidate_path.is_absolute() or any(part in {"", ".", ".."} for part in candidate_path.parts):
        raise WorkspaceToolError(
            "file must be a repository-relative path without traversal",
            code="invalid_git_path",
            status=400,
        )
    try:
        candidate = (repository / candidate_path).resolve(strict=False)
        if os.path.commonpath((str(repository), str(candidate))) != str(repository):
            raise WorkspaceToolError(
                "file must stay inside the repository",
                code="invalid_git_path",
                status=400,
            )
    except ValueError as exc:
        raise WorkspaceToolError(
            "file must stay inside the repository",
            code="invalid_git_path",
            status=400,
        ) from exc
    return candidate_path.as_posix()


def git_diff(root: Path, file: Any, section: str) -> dict:
    repository = git_root(root)
    relative = _relative_git_path(repository, file)
    if section == "staged":
        args = ["diff", "--cached", "--", relative]
        accepted_codes = (0,)
    elif section == "unstaged":
        args = ["diff", "--", relative]
        accepted_codes = (0,)
    elif section == "untracked":
        candidate = repository / relative
        if not candidate.is_file():
            raise WorkspaceToolError("File not found", code="git_file_not_found", status=404)
        args = ["diff", "--no-index", "--", "/dev/null", relative]
        accepted_codes = (0, 1)
    else:
        raise WorkspaceToolError(
            "section must be staged, unstaged, or untracked",
            code="invalid_git_section",
            status=400,
        )
    output, truncated = _git(
        repository,
        args,
        accepted_codes=accepted_codes,
        maximum_bytes=MAX_DIFF_BYTES,
    )
    return {"file": relative, "section": section, "diff": output, "truncated": truncated}


def git_stage(root: Path, file: Any) -> str:
    repository = git_root(root)
    relative = _relative_git_path(repository, file)
    _git(repository, ["add", "--", relative])
    return relative


def git_unstage(root: Path, file: Any) -> str:
    repository = git_root(root)
    relative = _relative_git_path(repository, file)
    try:
        _git(repository, ["rev-parse", "--verify", "HEAD"])
    except WorkspaceToolError:
        _git(repository, ["rm", "--cached", "-q", "--", relative])
    else:
        _git(repository, ["reset", "-q", "HEAD", "--", relative])
    return relative


def _skill_items(directory: Path, *, scope: str, base: Path, home_relative: bool) -> list[dict]:
    if not directory.is_dir():
        return []
    values: list[dict] = []
    try:
        children = sorted(directory.iterdir(), key=lambda path: path.name.casefold())
    except OSError:
        return []
    for child in children:
        skill_file = child / "SKILL.md"
        if not child.is_dir() or not skill_file.is_file():
            continue
        try:
            relative = skill_file.relative_to(base).as_posix()
        except ValueError:
            continue
        path = f"~/{relative}" if home_relative else relative
        values.append({"name": child.name, "skill_file_path": path, "scope": scope})
    return values


def skills(root: Path, *, environ: Optional[Mapping[str, str]] = None) -> dict:
    project_root = _skills_project_root(root)
    project = _skill_items(
        project_root / ".claude" / "skills",
        scope="project",
        base=project_root,
        home_relative=False,
    )
    env = os.environ if environ is None else environ
    home = Path(env.get("HOME") or Path.home()).expanduser().resolve()
    user = _skill_items(
        home / ".claude" / "skills",
        scope="user",
        base=home,
        home_relative=True,
    )
    return {
        "root_path": str(project_root),
        "project_skills": project,
        "user_skills": user,
        "skills": project + user,
    }


def _read_gitignore_patterns(root: Path) -> list[str]:
    try:
        lines = (root / ".gitignore").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return []
    return [line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")]


def _matches_gitignore(path: str, basename: str, patterns: list[str]) -> bool:
    normalized = path.strip("/")
    ignored = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        raw = pattern[1:] if negated else pattern
        directory_only = raw.endswith("/")
        raw = raw.strip("/")
        if not raw:
            continue
        if "/" in raw:
            matched = fnmatch.fnmatch(normalized, raw) or (
                directory_only and normalized.startswith(raw + "/")
            )
        else:
            matched = fnmatch.fnmatch(basename, raw)
        if matched:
            ignored = not negated
    return ignored


def _walk_project_files(root: Path) -> list[str]:
    patterns = _read_gitignore_patterns(root)
    paths: list[str] = []
    for current_root, directories, files in os.walk(root):
        current = Path(current_root)
        relative_directory = current.relative_to(root).as_posix()
        directories[:] = [
            name
            for name in directories
            if name not in _SEARCH_EXCLUDED_DIRS
            and not _matches_gitignore(
                (name if relative_directory == "." else f"{relative_directory}/{name}") + "/",
                name,
                patterns,
            )
        ]
        for filename in files:
            relative = (current / filename).relative_to(root).as_posix()
            if not _matches_gitignore(relative, filename, patterns):
                paths.append(relative)
    return sorted(paths, key=str.casefold)


def _project_files(root: Path) -> list[str]:
    try:
        output, _ = _git(
            root,
            ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        )
    except WorkspaceToolError:
        return _walk_project_files(root)
    paths = set()
    for path in output.split("\0"):
        normalized = path.replace("\\", "/")
        if not normalized or normalized.startswith("../") or os.path.isabs(normalized):
            continue
        if any(part in _SEARCH_EXCLUDED_DIRS for part in Path(normalized).parts[:-1]):
            continue
        paths.add(normalized)
    return sorted(paths, key=str.casefold)


def search_files(root: Path, query: str, *, limit: int = 80) -> dict:
    project_root = _project_root(root)
    query = str(query or "").strip()
    if len(query) > 512 or "\x00" in query:
        raise WorkspaceToolError("query is invalid", code="invalid_file_query", status=400)
    limit = max(1, min(int(limit), MAX_FILE_RESULTS))
    if not query:
        return {
            "root_path": str(project_root),
            "query": query,
            "files": [],
            "truncated": False,
            "limit": limit,
        }
    needle = query.casefold()
    matches: list[dict] = []
    for path in _project_files(project_root):
        if needle not in path.casefold():
            continue
        matches.append({"path": path})
        if len(matches) > limit:
            break
    return {
        "root_path": str(project_root),
        "query": query,
        "files": matches[:limit],
        "truncated": len(matches) > limit,
        "limit": limit,
    }


def _clean_external_text(value: Any, *, maximum: int = 2_000) -> str:
    text = str(value or "")
    text = "".join(character for character in text if character in "\n\t" or ord(character) >= 32)
    return text.strip()[:maximum]


def normalize_jira_key(value: Any) -> Optional[str]:
    match = _JIRA_KEY_RE.search(str(value or ""))
    return match.group(1).upper() if match else None


def _jira_site(environ: Mapping[str, str]) -> str:
    for name in ("HERDR_HARNESS_JIRA_SITE", "JIRA_SITE", "ATLASSIAN_SITE"):
        value = str(environ.get(name) or "").strip()
        if value:
            return re.sub(r"^https?://", "", value).strip("/")
    home = Path(environ.get("HOME") or Path.home()).expanduser()
    for path in (
        home / ".config" / "atlassian-cli" / "jira_config.yaml",
        home / ".config" / "acli" / "jira_config.yaml",
    ):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        match = re.search(r"(?m)^\s*-?\s*site:\s*([^\s#]+)", text)
        if match:
            return re.sub(r"^https?://", "", match.group(1)).strip("/")
    return "example.atlassian.net"


def _field_name(value: Any) -> str:
    if isinstance(value, dict):
        value = value.get("name")
    return _clean_external_text(value, maximum=200)


def _normalize_jira_items(items: Any, *, site: str) -> list[dict]:
    if not isinstance(items, list):
        raise WorkspaceToolError(
            "Jira returned an unexpected response",
            code="jira_invalid_response",
            status=502,
        )
    tickets: list[dict] = []
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("fields"), dict):
            continue
        key = normalize_jira_key(item.get("key"))
        if not key:
            continue
        fields = item["fields"]
        tickets.append(
            {
                "key": key,
                "project_key": key.split("-", 1)[0],
                "title": _clean_external_text(fields.get("summary"), maximum=1_000),
                "status": _field_name(fields.get("status")),
                "priority": _field_name(fields.get("priority")),
                "issue_type": _field_name(fields.get("issuetype")),
                "url": f"https://{site}/browse/{key}",
            }
        )
    return sorted(tickets, key=lambda ticket: ticket["key"].casefold())


def _jira_search(jql: str, *, limit: int, environ: Mapping[str, str]) -> tuple[str, list[dict]]:
    maximum = max(1, min(int(limit), 100))
    output, _ = _run(
        [
            "acli",
            "jira",
            "workitem",
            "search",
            "--jql",
            jql,
            "--fields",
            "key,status,summary,issuetype,priority",
            "--limit",
            str(maximum),
            "--json",
        ],
        timeout=JIRA_TIMEOUT_SECONDS,
    )
    try:
        payload = json.loads(output or "[]")
    except json.JSONDecodeError as exc:
        raise WorkspaceToolError(
            "Jira returned invalid JSON",
            code="jira_invalid_response",
            status=502,
        ) from exc
    site = _jira_site(environ)
    return site, _normalize_jira_items(payload, site=site)


def jira_assigned(
    *,
    project: str = "",
    limit: int = 50,
    environ: Optional[Mapping[str, str]] = None,
) -> dict:
    project = str(project or "").strip().upper()
    if project and not _PROJECT_KEY_RE.fullmatch(project):
        raise WorkspaceToolError("project is invalid", code="invalid_jira_project", status=400)
    clause = f" AND project = {project}" if project else ""
    jql = (
        "assignee = currentUser()"
        f"{clause}"
        " AND statusCategory != Done"
        " ORDER BY updated DESC"
    )
    env = os.environ if environ is None else environ
    site, tickets = _jira_search(jql, limit=limit, environ=env)
    return {
        "project": project or None,
        "projects": sorted({ticket["project_key"] for ticket in tickets}),
        "site": site,
        "tickets": tickets,
    }


def jira_issue(query: str, *, environ: Optional[Mapping[str, str]] = None) -> dict:
    key = normalize_jira_key(query)
    if not key:
        raise WorkspaceToolError(
            "A valid Jira key or URL is required",
            code="invalid_jira_key",
            status=400,
        )
    env = os.environ if environ is None else environ
    site, tickets = _jira_search(f"key = {key}", limit=1, environ=env)
    if not tickets:
        raise WorkspaceToolError(
            f"Jira ticket {key} was not found",
            code="jira_issue_not_found",
            status=404,
        )
    return {"site": site, "ticket": tickets[0]}
