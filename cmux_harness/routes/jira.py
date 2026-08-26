from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from ..text_sanitizer import clean_external_text


FALLBACK_JIRA_SITE = "example.atlassian.net"
DEFAULT_LIMIT = 50
MAX_LIMIT = 100
_PROJECT_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
_JIRA_KEY_RE = re.compile(r"\b([A-Z][A-Z0-9_]+-\d+)\b", re.IGNORECASE)


class JiraRouteError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def handle_get_assigned(handler, parsed):
    params = handler.parse_qs(parsed.query)
    project = str(params.get("project", [""])[0] or "").strip().upper()
    site = str(params.get("site", [default_jira_site()])[0] or "").strip() or default_jira_site()

    try:
        limit = int(str(params.get("limit", [str(DEFAULT_LIMIT)])[0] or str(DEFAULT_LIMIT)))
    except (TypeError, ValueError):
        limit = DEFAULT_LIMIT
    limit = max(1, min(limit, MAX_LIMIT))

    try:
        tickets = fetch_assigned_tickets(project=project, limit=limit, site=site)
    except JiraRouteError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, exc.status)
        return

    handler._json_response({
        "ok": True,
        "project": project or None,
        "projects": ticket_projects(tickets),
        "site": site,
        "tickets": tickets,
    })


def handle_get_issue(handler, parsed):
    params = handler.parse_qs(parsed.query)
    query = str(params.get("q", params.get("key", [""]))[0] or "").strip()
    site = str(params.get("site", [default_jira_site()])[0] or "").strip() or default_jira_site()
    key = extract_jira_key(query)
    if not key:
        handler._json_response({"ok": False, "error": "valid Jira key or URL required"}, 400)
        return

    try:
        ticket = fetch_ticket(key=key, site=site)
    except JiraRouteError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, exc.status)
        return

    handler._json_response({
        "ok": True,
        "site": site,
        "ticket": ticket,
    })


def fetch_assigned_tickets(*, project: str = "", limit: int = DEFAULT_LIMIT, site: str | None = None):
    jql = build_assigned_jql(project)
    return normalize_workitems(run_workitem_search(jql, limit=limit), site=site)


def fetch_ticket(*, key: str, site: str | None = None):
    key = normalize_jira_key(key)
    if not key:
        raise JiraRouteError("invalid Jira key", 400)
    tickets = normalize_workitems(run_workitem_search(build_issue_jql(key), limit=1), site=site)
    if not tickets:
        raise JiraRouteError(f"Jira ticket {key} not found", 404)
    return tickets[0]


def post_comment(*, key: str, body: str) -> dict:
    key = normalize_jira_key(key)
    if not key:
        raise JiraRouteError("invalid Jira key", 400)
    text = str(body or "").strip()
    if not text:
        raise JiraRouteError("comment body required", 400)
    command = [
        "acli",
        "jira",
        "workitem",
        "comment",
        "create",
        "--key",
        key,
        "--body",
        text,
        "--json",
    ]
    return _run_json_command(command, default={"key": key})


def transition_status(*, key: str, status: str) -> dict:
    key = normalize_jira_key(key)
    if not key:
        raise JiraRouteError("invalid Jira key", 400)
    target_status = clean_external_text(status)
    if not target_status:
        raise JiraRouteError("target status required", 400)
    command = [
        "acli",
        "jira",
        "workitem",
        "transition",
        "--key",
        key,
        "--status",
        target_status,
        "--yes",
        "--json",
    ]
    return _run_json_command(command, default={"key": key, "status": target_status})


def _run_json_command(command: list[str], *, default: dict | None = None) -> dict:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
    except FileNotFoundError as exc:
        raise JiraRouteError("acli is not installed or is not on PATH", 500) from exc
    except subprocess.TimeoutExpired as exc:
        raise JiraRouteError("Jira request timed out", 504) from exc
    except OSError as exc:
        raise JiraRouteError(f"Jira request failed: {exc}", 500) from exc
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Jira request failed").strip()
        raise JiraRouteError(message, 502)
    text = (result.stdout or "").strip()
    if not text:
        return default or {}
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return {**(default or {}), "raw": clean_external_text(text)}
    return payload if isinstance(payload, dict) else {"items": payload}


def run_workitem_search(jql: str, *, limit: int = DEFAULT_LIMIT):
    command = [
        "acli",
        "jira",
        "workitem",
        "search",
        "--jql",
        jql,
        "--fields",
        "key,status,summary,issuetype,priority",
        "--limit",
        str(max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))),
        "--json",
    ]

    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except FileNotFoundError as exc:
        raise JiraRouteError("acli is not installed or is not on PATH", 500) from exc
    except subprocess.TimeoutExpired as exc:
        raise JiraRouteError("Jira request timed out", 504) from exc
    except OSError as exc:
        raise JiraRouteError(f"Jira request failed: {exc}", 500) from exc

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Jira request failed").strip()
        raise JiraRouteError(message, 502)

    try:
        data = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        raise JiraRouteError("Jira returned invalid JSON", 502) from exc
    if not isinstance(data, list):
        raise JiraRouteError("Jira returned an unexpected response", 502)

    return data


def build_assigned_jql(project: str = "") -> str:
    project = str(project or "").strip().upper()
    if not project:
        project_clause = ""
    elif not _PROJECT_KEY_RE.fullmatch(project):
        raise JiraRouteError("invalid Jira project key", 400)
    else:
        project_clause = f" AND project = {project}"

    return (
        "assignee = currentUser()"
        f"{project_clause}"
        " AND statusCategory != Done"
        " ORDER BY updated DESC"
    )


def build_issue_jql(key: str) -> str:
    key = normalize_jira_key(key)
    if not key:
        raise JiraRouteError("invalid Jira key", 400)
    return f"key = {key}"


def extract_jira_key(value: str):
    match = _JIRA_KEY_RE.search(str(value or ""))
    if not match:
        return None
    return normalize_jira_key(match.group(1))


def normalize_jira_key(value: str):
    key = str(value or "").strip().upper()
    if not _JIRA_KEY_RE.fullmatch(key):
        return None
    return key


def normalize_workitems(workitems, *, site: str | None = None):
    tickets = []
    normalized_site = normalize_site(site)
    for item in workitems:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip().upper()
        fields = item.get("fields")
        if not key or not isinstance(fields, dict):
            continue

        title = clean_external_text(fields.get("summary"))
        status = _field_name(fields.get("status"))
        priority = _field_name(fields.get("priority"))
        issue_type = _field_name(fields.get("issuetype"))

        tickets.append({
            "key": key,
            "projectKey": project_key_from_issue_key(key),
            "title": title,
            "status": status,
            "priority": priority,
            "issueType": issue_type,
            "url": f"https://{normalized_site}/browse/{key}",
        })

    return sorted(tickets, key=lambda ticket: ticket["key"].casefold())


def ticket_projects(tickets) -> list[str]:
    projects = {
        str(ticket.get("projectKey") or "").strip().upper()
        for ticket in tickets
        if isinstance(ticket, dict)
    }
    return sorted(project for project in projects if project)


def project_key_from_issue_key(key: str) -> str:
    value = str(key or "").strip().upper()
    if "-" not in value:
        return ""
    return value.split("-", 1)[0]


def default_jira_site() -> str:
    """Return the active Jira Cloud site, preferring local acli auth config.

    The web UI uses this to build browser links. The acli command already knows
    which Atlassian tenant to query, so hard-coding example.atlassian.net here
    creates working ticket data with broken links.
    """
    for env_name in ("CMUX_JIRA_SITE", "JIRA_SITE", "ATLASSIAN_SITE"):
        value = normalize_site(os.environ.get(env_name), fallback="")
        if value:
            return value

    config_site = _read_acli_jira_site()
    if config_site:
        return config_site

    return FALLBACK_JIRA_SITE


def _read_acli_jira_site() -> str:
    for config_path in (
        Path.home() / ".config" / "atlassian-cli" / "jira_config.yaml",
        Path.home() / ".config" / "acli" / "jira_config.yaml",
    ):
        try:
            text = config_path.read_text(encoding="utf-8")
        except OSError:
            continue

        match = re.search(r"(?m)^\s*-?\s*site:\s*([^\s#]+)", text)
        if match:
            return normalize_site(match.group(1), fallback="")
    return ""


def normalize_site(site: str | None, *, fallback: str | None = None) -> str:
    value = str(site or (default_jira_site() if fallback is None else fallback) or "").strip()
    value = re.sub(r"^https?://", "", value)
    return value.strip("/")


def _field_name(value) -> str:
    if isinstance(value, dict):
        return str(value.get("name") or "").strip()
    return str(value or "").strip()
