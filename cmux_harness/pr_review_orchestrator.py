from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Any

from . import cmux_cli


DEFAULT_REPO = "doximity/iOS-Doximity"
DEFAULT_PROJECT_DIR = Path.home() / "Documents" / "Development" / "Doximity-Claude"
DEFAULT_REVIEW_CLI = "codex"
MODEL = "sonnet"

_SUPPORTED_REVIEW_CLIS = {"codex", "claude"}
_GITHUB_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class PRReviewOrchestratorError(RuntimeError):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def list_review_requests(
    *,
    repo: str = DEFAULT_REPO,
    limit: int = 20,
    fake: bool = False,
) -> list[dict[str, Any]]:
    repo = normalize_repo(repo)
    limit = max(1, min(int(limit or 20), 100))
    if fake:
        owner, repo_name = split_repo(repo)
        return [
            {
                "number": 11244,
                "title": "Adopt updated review prompt workflow",
                "url": f"https://github.com/{repo}/pull/11244",
                "branch": "rr/pr-review-workflow",
                "isDraft": False,
                "state": "OPEN",
                "owner": owner,
                "repo": repo_name,
                "author": "ronnie3786",
                "raw": {"fake": True},
            }
        ]

    payload = _run_gh_json(
        [
            "pr",
            "list",
            "--search",
            "review-requested:@me",
            "--repo",
            repo,
            "--json",
            "number,title,headRefName,url,isDraft,state,author",
            "--limit",
            str(limit),
        ],
        expected_type=list,
    )
    return [normalize_pr(item, repo=repo) for item in payload if isinstance(item, dict)]


def fetch_pull_request(
    *,
    number: Any,
    repo: str = DEFAULT_REPO,
    pull_request: dict[str, Any] | None = None,
    fake: bool = False,
) -> dict[str, Any]:
    repo = normalize_repo(repo)
    number_int = normalize_pr_number(number or (pull_request or {}).get("number"))
    if pull_request:
        normalized = normalize_pr({**pull_request, "number": number_int}, repo=repo)
        if normalized["number"] == number_int:
            return normalized
    if fake:
        owner, repo_name = split_repo(repo)
        return {
            "number": number_int,
            "title": f"Fake PR review target #{number_int}",
            "url": f"https://github.com/{repo}/pull/{number_int}",
            "branch": f"fake/pr-{number_int}",
            "isDraft": False,
            "state": "OPEN",
            "owner": owner,
            "repo": repo_name,
            "author": "ronnie3786",
            "raw": {"fake": True},
        }
    payload = _run_gh_json(
        [
            "pr",
            "view",
            str(number_int),
            "--repo",
            repo,
            "--json",
            "number,title,headRefName,url,isDraft,state,author",
        ],
        expected_type=dict,
    )
    return normalize_pr(payload, repo=repo)


def launch_review_workspace(
    *,
    number: Any,
    repo: str = DEFAULT_REPO,
    project_dir: str | Path = DEFAULT_PROJECT_DIR,
    review_cli: str = DEFAULT_REVIEW_CLI,
    pull_request: dict[str, Any] | None = None,
    title: str | None = None,
    cmux: cmux_cli.CmuxCli | None = None,
    fake: bool = False,
) -> dict[str, Any]:
    project_path = resolve_project_dir(project_dir)
    review_cli = normalize_review_cli(review_cli)
    pr = fetch_pull_request(number=number, repo=repo, pull_request=pull_request, fake=fake)
    session_title = str(title or f"PR-Review-{pr['number']}").strip()
    prompt = review_prompt(pr["number"], review_cli=review_cli)
    command = build_review_command(pr["number"], review_cli=review_cli, project_dir=project_path)
    cmux_client = cmux or cmux_cli.get_cli()
    session = cmux_client.create_session_with_command(
        title=session_title,
        cwd=str(project_path),
        command=command,
        launch_type=review_launch_type(review_cli),
    )
    return {
        "pullRequest": pr,
        "cmuxSession": session,
        "reviewCli": review_cli,
        "launchType": review_launch_type(review_cli),
        "projectDir": str(project_path),
        "prompt": prompt,
        "command": command,
    }


def build_review_command(
    number: Any,
    *,
    review_cli: str = DEFAULT_REVIEW_CLI,
    project_dir: str | Path = DEFAULT_PROJECT_DIR,
) -> str:
    number_int = normalize_pr_number(number)
    project_path = resolve_project_dir(project_dir)
    review_cli = normalize_review_cli(review_cli)
    if review_cli == "claude":
        return shell_join(
            [
                _resolve_executable("claude", "CMUX_PR_REVIEW_CLAUDE_PATH", "/Applications/cmux.app/Contents/Resources/bin/claude"),
                "--permission-mode",
                "auto",
                "--model",
                MODEL,
                "--name",
                f"PR-Review-{number_int}",
                review_prompt(number_int, review_cli=review_cli),
            ]
        )
    return shell_join(
        [
            _resolve_executable("codex", "CMUX_PR_REVIEW_CODEX_PATH", str(Path.home() / ".local" / "bin" / "codex")),
            "--cd",
            str(project_path),
            "--sandbox",
            "workspace-write",
            "--ask-for-approval",
            "on-request",
            "--no-alt-screen",
            review_prompt(number_int, review_cli=review_cli),
        ]
    )


def review_prompt(number: Any, *, review_cli: str = DEFAULT_REVIEW_CLI) -> str:
    number_int = normalize_pr_number(number)
    if normalize_review_cli(review_cli) == "claude":
        return f"/ios-review-remote-pr {number_int}"
    return f"$ios-review-remote-pr {number_int}"


def review_launch_type(review_cli: str) -> str:
    return "Claude Code" if normalize_review_cli(review_cli) == "claude" else "Codex"


def normalize_repo(value: Any) -> str:
    repo = str(value or DEFAULT_REPO).strip()
    if not _GITHUB_REPO_RE.fullmatch(repo):
        raise PRReviewOrchestratorError("repo must be in owner/name form", 400)
    return repo


def split_repo(repo: str) -> tuple[str, str]:
    owner, repo_name = normalize_repo(repo).split("/", 1)
    return owner, repo_name


def normalize_review_cli(value: Any) -> str:
    review_cli = str(value or DEFAULT_REVIEW_CLI).strip().lower()
    if review_cli not in _SUPPORTED_REVIEW_CLIS:
        raise PRReviewOrchestratorError("reviewCli must be 'codex' or 'claude'", 400)
    return review_cli


def normalize_pr_number(value: Any) -> int:
    try:
        number = int(str(value or "").strip())
    except (TypeError, ValueError) as exc:
        raise PRReviewOrchestratorError("PR number required", 400) from exc
    if number <= 0:
        raise PRReviewOrchestratorError("PR number required", 400)
    return number


def resolve_project_dir(value: str | Path) -> Path:
    path = Path(value or DEFAULT_PROJECT_DIR).expanduser().resolve()
    if not path.is_dir():
        raise PRReviewOrchestratorError(f"projectDir not found: {path}", 400)
    return path


def normalize_pr(item: dict[str, Any], *, repo: str) -> dict[str, Any]:
    owner, repo_name = split_repo(repo)
    author = item.get("author") if isinstance(item.get("author"), dict) else {}
    repository = item.get("repository") if isinstance(item.get("repository"), dict) else {}
    repository_owner = repository.get("owner") if isinstance(repository.get("owner"), dict) else {}
    name_with_owner = str(repository.get("nameWithOwner") or repository.get("name_with_owner") or "")
    payload_owner, _, payload_repo = name_with_owner.partition("/")
    url = str(item.get("url") or "")
    url_owner, url_repo = _repo_from_pr_url(url)
    return {
        "number": normalize_pr_number(item.get("number")),
        "title": str(item.get("title") or ""),
        "url": url,
        "branch": str(item.get("headRefName") or item.get("branch") or ""),
        "isDraft": bool(item.get("isDraft") or item.get("is_draft")),
        "state": str(item.get("state") or ""),
        "owner": str(item.get("owner") or repository_owner.get("login") or payload_owner or url_owner or owner),
        "repo": str(item.get("repo") or repository.get("name") or payload_repo or url_repo or repo_name),
        "author": str(author.get("login") or item.get("author") or ""),
        "raw": item,
    }


def shell_join(args: list[Any]) -> str:
    return " ".join(shlex.quote(str(arg)) for arg in args)


def _run_gh_json(args: list[str], *, expected_type: type) -> Any:
    env = os.environ.copy()
    env["GH_NO_UPDATE_NOTIFIER"] = "1"
    env["NO_COLOR"] = "1"
    command = [_resolve_executable("gh", "CMUX_PR_REVIEW_GH_PATH", "/opt/homebrew/bin/gh"), *args]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
            env=env,
        )
    except FileNotFoundError as exc:
        raise PRReviewOrchestratorError("gh is not installed or is not on PATH", 500) from exc
    except subprocess.TimeoutExpired as exc:
        raise PRReviewOrchestratorError("GitHub request timed out", 504) from exc
    except OSError as exc:
        raise PRReviewOrchestratorError(f"GitHub request failed: {exc}", 500) from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "GitHub request failed").strip()
        raise PRReviewOrchestratorError(message, 502)
    try:
        payload = json.loads(result.stdout or ("[]" if expected_type is list else "{}"))
    except json.JSONDecodeError as exc:
        raise PRReviewOrchestratorError("GitHub returned invalid JSON", 502) from exc
    if not isinstance(payload, expected_type):
        raise PRReviewOrchestratorError("GitHub returned an unexpected response", 502)
    return payload


def _resolve_executable(command: str, env_name: str, fallback: str) -> str:
    configured = str(os.environ.get(env_name) or "").strip()
    if configured:
        return str(Path(configured).expanduser())
    return shutil.which(command) or fallback


def _repo_from_pr_url(url: str) -> tuple[str, str]:
    match = re.search(r"github\.com/([^/]+)/([^/]+)/pull/\d+", str(url or ""))
    if not match:
        return "", ""
    return match.group(1), match.group(2)
