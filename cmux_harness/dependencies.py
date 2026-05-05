from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from datetime import datetime, timezone
from typing import Any

from .routes import jira
from .text_sanitizer import clean_external_text


_CACHE_TTL_SECONDS = 60
_COMMAND_TIMEOUT_SECONDS = 6
_VERSION_TIMEOUT_SECONDS = 3
_MAX_DIAGNOSTIC_CHARS = 900
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_CACHE_LOCK = threading.Lock()
_CACHE: dict[str, Any] | None = None
_CACHE_EXPIRES_AT = 0.0


def clear_cache() -> None:
    global _CACHE, _CACHE_EXPIRES_AT
    with _CACHE_LOCK:
        _CACHE = None
        _CACHE_EXPIRES_AT = 0.0


def check_cli_requirements(*, force: bool = False) -> dict[str, Any]:
    global _CACHE, _CACHE_EXPIRES_AT

    now = time.time()
    with _CACHE_LOCK:
        if not force and _CACHE is not None and now < _CACHE_EXPIRES_AT:
            return _CACHE

    items = [_check_github_cli(), _check_atlassian_cli()]
    payload = {
        "ok": all(item["ok"] for item in items),
        "checkedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "items": items,
    }

    with _CACHE_LOCK:
        _CACHE = payload
        _CACHE_EXPIRES_AT = time.time() + _CACHE_TTL_SECONDS

    return payload


def _check_github_cli() -> dict[str, Any]:
    return _check_cli(
        id="github",
        name="GitHub CLI",
        command="gh",
        version_args=["--version"],
        setup_args=["auth", "status", "--hostname", "github.com"],
        check_label="gh auth status --hostname github.com",
        why_required=(
            "GitHub PR comments in the iOS app and dashboard are loaded through the local "
            "server with gh. The workspace must also be a GitHub repo with a pull request "
            "for the current branch."
        ),
        setup_hint=(
            "Install GitHub CLI, then run `gh auth login --hostname github.com` and grant "
            "repo access for the account that can read your pull requests."
        ),
        configured_summary="gh is installed and authenticated for github.com.",
        unconfigured_summary="gh is installed, but GitHub authentication is not ready.",
        env_overrides={"GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"},
    )


def _check_atlassian_cli() -> dict[str, Any]:
    jql = jira.build_assigned_jql()
    return _check_cli(
        id="atlassian",
        name="Atlassian CLI",
        command="acli",
        version_args=["--version"],
        setup_args=[
            "jira",
            "workitem",
            "search",
            "--jql",
            jql,
            "--fields",
            "key,status,summary",
            "--limit",
            "1",
            "--json",
        ],
        check_label="acli jira workitem search --limit 1 --json",
        why_required=(
            "Jira ticket lookup, assigned-ticket browsing, and Jira prompt references use "
            "Atlassian's acli from the local server. The CLI needs a default Jira site and "
            "an authenticated account."
        ),
        setup_hint=(
            "Install Atlassian CLI, then run `acli jira auth login` and confirm "
            "`acli jira workitem search --jql \"assignee = currentUser()\" --limit 1 --json` "
            "returns JSON."
        ),
        configured_summary="acli is installed and can query Jira workitems.",
        unconfigured_summary="acli is installed, but Jira workitem search is not ready.",
        env_overrides={"NO_COLOR": "1"},
    )


def _check_cli(
    *,
    id: str,
    name: str,
    command: str,
    version_args: list[str],
    setup_args: list[str],
    check_label: str,
    why_required: str,
    setup_hint: str,
    configured_summary: str,
    unconfigured_summary: str,
    env_overrides: dict[str, str] | None = None,
) -> dict[str, Any]:
    path = shutil.which(command) or ""
    base = {
        "id": id,
        "name": name,
        "command": command,
        "path": path,
        "version": "",
        "available": False,
        "configured": False,
        "ok": False,
        "status": "missing",
        "summary": f"{command} is not installed or is not on PATH.",
        "check": check_label,
        "diagnostic": "",
        "whyRequired": why_required,
        "setupHint": setup_hint,
    }
    if not path:
        return base

    version = _run_command([path, *version_args], timeout=_VERSION_TIMEOUT_SECONDS, env_overrides=env_overrides)
    base["path"] = path
    base["diagnostic"] = version["output"]
    if not version["ok"]:
        base["available"] = True
        base["status"] = "error"
        base["summary"] = f"{command} was found, but the version check failed."
        return base

    base["available"] = True
    base["version"] = _first_line(version["output"])

    setup = _run_command([path, *setup_args], timeout=_COMMAND_TIMEOUT_SECONDS, env_overrides=env_overrides)
    if setup["ok"]:
        base["configured"] = True
        base["ok"] = True
        base["status"] = "ok"
        base["summary"] = configured_summary
        base["diagnostic"] = "Diagnostic check completed successfully."
    else:
        base["diagnostic"] = setup["output"] or version["output"]
        base["status"] = "needs_setup"
        base["summary"] = unconfigured_summary
    return base


def _run_command(command: list[str], *, timeout: int, env_overrides: dict[str, str] | None = None) -> dict[str, Any]:
    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": f"{_display_command(command)} timed out after {timeout}s."}
    except OSError as exc:
        return {"ok": False, "output": f"{_display_command(command)} failed: {exc}"}

    output = clean_external_text(_clean_output(result.stdout, result.stderr))
    return {"ok": result.returncode == 0, "output": output}


def _clean_output(*parts: str) -> str:
    output = "\n".join(str(part or "").strip() for part in parts if str(part or "").strip())
    output = _ANSI_RE.sub("", output)
    output = "\n".join(line.rstrip() for line in output.splitlines() if line.strip())
    if len(output) > _MAX_DIAGNOSTIC_CHARS:
        output = output[:_MAX_DIAGNOSTIC_CHARS].rstrip() + "..."
    return output


def _display_command(command: list[str]) -> str:
    if not command:
        return ""
    return " ".join([os.path.basename(command[0]), *command[1:]])


def _first_line(output: str) -> str:
    for line in str(output or "").splitlines():
        line = line.strip()
        if line:
            return line
    return ""
