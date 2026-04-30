from __future__ import annotations

import json
import os
import re
import subprocess
from typing import Any


DEFAULT_TIMEOUT_SECONDS = 20
MAX_THREAD_PAGES = 20
CODE_CONTEXT_BEFORE_LINES = 2
CODE_CONTEXT_AFTER_LINES = 2
MAX_CODE_CONTEXT_LINE_LENGTH = 500

_GITHUB_PR_URL_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)(?:[/?#].*)?$")
_HUNK_HEADER_RE = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")

_REVIEW_THREADS_QUERY = """
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          startDiffSide
          subjectType
          comments(first: 50) {
            nodes {
              id
              author {
                login
              }
              body
              bodyText
              createdAt
              updatedAt
              url
              diffHunk
              path
              line
              originalLine
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}
"""


class GitHubRouteError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def handle_get_pr_comments(handler, parsed, *, engine) -> None:
    params = handler.parse_qs(parsed.query)
    include_resolved = _parse_bool(params.get("includeResolved", ["false"])[0])

    try:
        cwd = _resolve_request_cwd(handler, params, engine=engine)
        response = fetch_pr_review_threads(cwd, include_resolved=include_resolved)
    except GitHubRouteError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, exc.status)
        return

    handler._json_response({"ok": True, **response})


def fetch_pr_review_threads(cwd: str, *, include_resolved: bool = False) -> dict[str, Any]:
    cwd = os.path.realpath(str(cwd or "").strip())
    if not cwd or not os.path.isdir(cwd):
        raise GitHubRouteError("workspace cwd not found", 404)

    pr = _detect_current_pr(cwd)
    owner, repo, number_from_url = _parse_github_pr_url(str(pr.get("url") or ""))
    number = _int_or_none(pr.get("number")) or number_from_url

    all_threads = _with_code_contexts(_fetch_review_threads(cwd, owner=owner, repo=repo, number=number), cwd)
    visible_threads = [thread for thread in all_threads if include_resolved or not thread["isResolved"]]
    resolved_count = sum(1 for thread in all_threads if thread["isResolved"])

    return {
        "cwd": cwd,
        "repository": {
            "owner": owner,
            "name": repo,
            "url": f"https://github.com/{owner}/{repo}",
        },
        "pullRequest": {
            "number": number,
            "title": str(pr.get("title") or ""),
            "url": str(pr.get("url") or ""),
            "headRefName": str(pr.get("headRefName") or ""),
            "baseRefName": str(pr.get("baseRefName") or ""),
            "state": str(pr.get("state") or ""),
            "author": _author_login(pr.get("author")),
        },
        "includeResolved": include_resolved,
        "threads": visible_threads,
        "files": _group_threads_by_file(visible_threads),
        "totalThreadCount": len(all_threads),
        "returnedThreadCount": len(visible_threads),
        "resolvedThreadCount": resolved_count,
        "hiddenResolvedCount": 0 if include_resolved else resolved_count,
    }


def _resolve_request_cwd(handler, params, *, engine) -> str:
    path_value = params.get("path", [None])[0]
    if path_value:
        cwd = handler._resolve_git_path(path_value)
        if cwd is None:
            raise GitHubRouteError("path required", 400)
        return cwd

    idx_str = params.get("index", [None])[0]
    if idx_str is None:
        raise GitHubRouteError("index or path required", 400)
    try:
        idx = int(idx_str)
    except (TypeError, ValueError) as exc:
        raise GitHubRouteError("invalid index", 400) from exc

    cwd = engine._get_workspace_cwd(idx)
    if not cwd:
        raise GitHubRouteError("workspace cwd not found", 404)
    return cwd


def _detect_current_pr(cwd: str) -> dict[str, Any]:
    return _run_gh_json(
        cwd,
        [
            "pr",
            "view",
            "--json",
            "number,title,url,headRefName,baseRefName,state,author",
        ],
        not_found_message="No GitHub pull request found for the current branch",
    )


def _fetch_review_threads(cwd: str, *, owner: str, repo: str, number: int) -> list[dict[str, Any]]:
    threads: list[dict[str, Any]] = []
    after: str | None = None

    for _page in range(MAX_THREAD_PAGES):
        command = [
            "api",
            "graphql",
            "-F",
            f"owner={owner}",
            "-F",
            f"repo={repo}",
            "-F",
            f"number={number}",
            "-f",
            f"query={_REVIEW_THREADS_QUERY}",
        ]
        if after:
            command.extend(["-f", f"after={after}"])

        payload = _run_gh_json(cwd, command)
        errors = payload.get("errors")
        if errors:
            message = "; ".join(str(error.get("message") or error) for error in errors if isinstance(error, dict))
            raise GitHubRouteError(message or "GitHub returned GraphQL errors", 502)

        review_threads = (
            payload.get("data", {})
            .get("repository", {})
            .get("pullRequest", {})
            .get("reviewThreads", {})
        )
        nodes = review_threads.get("nodes") if isinstance(review_threads, dict) else None
        if not isinstance(nodes, list):
            raise GitHubRouteError("GitHub returned an unexpected response", 502)

        for node in nodes:
            thread = _normalize_thread(node)
            if thread is not None:
                threads.append(thread)

        page_info = review_threads.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        after = str(page_info.get("endCursor") or "")
        if not after:
            break

    return sorted(threads, key=lambda item: (item["path"].casefold(), item["line"] or item["originalLine"] or 0))


def _run_gh_json(
    cwd: str,
    args: list[str],
    *,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    not_found_message: str | None = None,
) -> dict[str, Any]:
    env = os.environ.copy()
    env["GH_NO_UPDATE_NOTIFIER"] = "1"
    env["NO_COLOR"] = "1"

    try:
        result = subprocess.run(
            ["gh", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except FileNotFoundError as exc:
        raise GitHubRouteError("gh is not installed or is not on PATH", 500) from exc
    except subprocess.TimeoutExpired as exc:
        raise GitHubRouteError("GitHub request timed out", 504) from exc
    except OSError as exc:
        raise GitHubRouteError(f"GitHub request failed: {exc}", 500) from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "GitHub request failed").strip()
        if not_found_message and _looks_like_missing_pr(message):
            raise GitHubRouteError(not_found_message, 404)
        raise GitHubRouteError(message, 502)

    try:
        parsed = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise GitHubRouteError("GitHub returned invalid JSON", 502) from exc
    if not isinstance(parsed, dict):
        raise GitHubRouteError("GitHub returned an unexpected response", 502)
    return parsed


def _parse_github_pr_url(url: str) -> tuple[str, str, int]:
    match = _GITHUB_PR_URL_RE.match(str(url or "").strip())
    if not match:
        raise GitHubRouteError("Only github.com pull requests are supported", 400)
    owner, repo, number = match.groups()
    return owner, repo, int(number)


def _normalize_thread(node: Any) -> dict[str, Any] | None:
    if not isinstance(node, dict):
        return None

    path = str(node.get("path") or "").strip()
    comments = [_normalize_comment(comment) for comment in _comment_nodes(node)]
    comments = [comment for comment in comments if comment is not None]
    if not path or not comments:
        return None

    line = _first_int(node.get("line"), *(comment.get("line") for comment in comments))
    original_line = _first_int(node.get("originalLine"), *(comment.get("originalLine") for comment in comments))
    start_line = _first_int(node.get("startLine"))
    original_start_line = _first_int(node.get("originalStartLine"))

    return {
        "id": str(node.get("id") or comments[0]["id"]),
        "path": path,
        "line": line,
        "originalLine": original_line,
        "startLine": start_line,
        "originalStartLine": original_start_line,
        "diffSide": str(node.get("diffSide") or ""),
        "startDiffSide": str(node.get("startDiffSide") or ""),
        "subjectType": str(node.get("subjectType") or ""),
        "isResolved": bool(node.get("isResolved")),
        "isOutdated": bool(node.get("isOutdated")),
        "url": comments[0].get("url") or "",
        "codeContext": None,
        "comments": comments,
    }


def _comment_nodes(node: dict[str, Any]) -> list[Any]:
    comments = node.get("comments")
    if not isinstance(comments, dict):
        return []
    nodes = comments.get("nodes")
    return nodes if isinstance(nodes, list) else []


def _normalize_comment(comment: Any) -> dict[str, Any] | None:
    if not isinstance(comment, dict):
        return None
    body = str(comment.get("body") or comment.get("bodyText") or "").strip()
    if not body:
        return None
    return {
        "id": str(comment.get("id") or ""),
        "author": _author_login(comment.get("author")),
        "body": body,
        "bodyText": str(comment.get("bodyText") or body).strip(),
        "createdAt": str(comment.get("createdAt") or ""),
        "updatedAt": str(comment.get("updatedAt") or ""),
        "url": str(comment.get("url") or ""),
        "diffHunk": str(comment.get("diffHunk") or ""),
        "path": str(comment.get("path") or ""),
        "line": _int_or_none(comment.get("line")),
        "originalLine": _int_or_none(comment.get("originalLine")),
    }


def _group_threads_by_file(threads: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    for thread in threads:
        groups.setdefault(thread["path"], []).append(thread)
    return [
        {
            "path": path,
            "threadCount": len(file_threads),
            "threads": file_threads,
        }
        for path, file_threads in sorted(groups.items(), key=lambda item: item[0].casefold())
    ]


def _with_code_contexts(threads: list[dict[str, Any]], cwd: str) -> list[dict[str, Any]]:
    return [{**thread, "codeContext": _thread_code_context(thread, cwd)} for thread in threads]


def _thread_code_context(thread: dict[str, Any], cwd: str) -> dict[str, Any] | None:
    return _workspace_code_context(thread, cwd) or _diff_hunk_code_context(thread)


def _workspace_code_context(thread: dict[str, Any], cwd: str) -> dict[str, Any] | None:
    if thread.get("isOutdated") or _thread_uses_left_side(thread):
        return None

    start_line, end_line = _thread_line_range(thread, side="RIGHT")
    if start_line is None or end_line is None:
        return None

    file_path = _safe_workspace_file_path(cwd, str(thread.get("path") or ""))
    if not file_path:
        return None

    context_start = max(1, start_line - CODE_CONTEXT_BEFORE_LINES)
    context_end = end_line + CODE_CONTEXT_AFTER_LINES
    lines: list[dict[str, Any]] = []
    has_target = False

    try:
        with open(file_path, encoding="utf-8", errors="replace") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                if line_number > context_end:
                    break
                if line_number < context_start:
                    continue
                is_target = start_line <= line_number <= end_line
                has_target = has_target or is_target
                lines.append(_code_context_line(line_number, raw_line.rstrip("\r\n"), is_target))
    except OSError:
        return None

    if not lines or not has_target:
        return None
    return _code_context(thread, source="workspace", start_line=start_line, end_line=end_line, lines=lines)


def _diff_hunk_code_context(thread: dict[str, Any]) -> dict[str, Any] | None:
    side = "LEFT" if _thread_uses_left_side(thread) else "RIGHT"
    start_line, end_line = _thread_line_range(thread, side=side)
    if start_line is None or end_line is None:
        return None

    hunk = next((str(comment.get("diffHunk") or "") for comment in thread.get("comments", []) if comment.get("diffHunk")), "")
    entries = _parse_diff_hunk(hunk)
    if not entries:
        return None

    number_key = "oldNumber" if side == "LEFT" else "newNumber"
    visible_entries = [entry for entry in entries if entry.get(number_key) is not None]
    target_indexes = [
        index
        for index, entry in enumerate(visible_entries)
        if start_line <= int(entry[number_key]) <= end_line
    ]
    if not target_indexes:
        return None

    first_index = max(0, min(target_indexes) - CODE_CONTEXT_BEFORE_LINES)
    last_index = min(len(visible_entries) - 1, max(target_indexes) + CODE_CONTEXT_AFTER_LINES)
    lines = [
        _code_context_line(
            int(entry[number_key]),
            str(entry.get("text") or ""),
            start_line <= int(entry[number_key]) <= end_line,
        )
        for entry in visible_entries[first_index : last_index + 1]
    ]
    return _code_context(thread, source="diffHunk", start_line=start_line, end_line=end_line, lines=lines)


def _parse_diff_hunk(hunk: str) -> list[dict[str, Any]]:
    if not hunk:
        return []

    lines = hunk.splitlines()
    if not lines:
        return []

    header = _HUNK_HEADER_RE.match(lines[0])
    if not header:
        return []

    old_number = int(header.group(1))
    new_number = int(header.group(2))
    entries: list[dict[str, Any]] = []

    for raw_line in lines[1:]:
        if raw_line.startswith("\\"):
            continue
        if raw_line.startswith("+") and not raw_line.startswith("+++"):
            entries.append({"oldNumber": None, "newNumber": new_number, "text": raw_line[1:]})
            new_number += 1
            continue
        if raw_line.startswith("-") and not raw_line.startswith("---"):
            entries.append({"oldNumber": old_number, "newNumber": None, "text": raw_line[1:]})
            old_number += 1
            continue

        text = raw_line[1:] if raw_line.startswith(" ") else raw_line
        entries.append({"oldNumber": old_number, "newNumber": new_number, "text": text})
        old_number += 1
        new_number += 1

    return entries


def _code_context(
    thread: dict[str, Any],
    *,
    source: str,
    start_line: int,
    end_line: int,
    lines: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "path": str(thread.get("path") or ""),
        "source": source,
        "startLine": start_line,
        "endLine": end_line,
        "lines": lines,
    }


def _code_context_line(number: int, text: str, is_target: bool) -> dict[str, Any]:
    return {
        "number": number,
        "text": _truncate_code_line(text),
        "isTarget": bool(is_target),
    }


def _thread_line_range(thread: dict[str, Any], *, side: str) -> tuple[int | None, int | None]:
    if side == "LEFT":
        start = _first_int(thread.get("originalStartLine"), thread.get("originalLine"), thread.get("startLine"), thread.get("line"))
        end = _first_int(thread.get("originalLine"), thread.get("line"), thread.get("originalStartLine"), thread.get("startLine"))
    else:
        start = _first_int(thread.get("startLine"), thread.get("line"), thread.get("originalStartLine"), thread.get("originalLine"))
        end = _first_int(thread.get("line"), thread.get("startLine"), thread.get("originalLine"), thread.get("originalStartLine"))
    if start is not None and end is not None and start > end:
        start, end = end, start
    return start, end


def _thread_uses_left_side(thread: dict[str, Any]) -> bool:
    return str(thread.get("diffSide") or "").upper() == "LEFT"


def _safe_workspace_file_path(cwd: str, path: str) -> str | None:
    path = str(path or "").strip()
    if not path or os.path.isabs(path):
        return None

    try:
        root = os.path.realpath(cwd)
        candidate = os.path.realpath(os.path.join(root, path))
        if os.path.commonpath([root, candidate]) != root:
            return None
    except (OSError, ValueError):
        return None

    return candidate if os.path.isfile(candidate) else None


def _truncate_code_line(text: str) -> str:
    if len(text) <= MAX_CODE_CONTEXT_LINE_LENGTH:
        return text
    return text[: MAX_CODE_CONTEXT_LINE_LENGTH - 3] + "..."


def _looks_like_missing_pr(message: str) -> bool:
    lowered = str(message or "").casefold()
    return (
        "no pull requests found" in lowered
        or "could not find a pull request" in lowered
        or "not found" in lowered
    )


def _parse_bool(value: Any) -> bool:
    return str(value or "").strip().casefold() in {"1", "true", "yes", "on"}


def _author_login(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("login") or "").strip()
    return str(value or "").strip()


def _first_int(*values: Any) -> int | None:
    for value in values:
        parsed = _int_or_none(value)
        if parsed is not None:
            return parsed
    return None


def _int_or_none(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
