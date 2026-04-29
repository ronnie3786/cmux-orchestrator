from __future__ import annotations

import json
import re
import subprocess


DEFAULT_JIRA_SITE = "doximity.atlassian.net"
DEFAULT_PROJECT_KEY = "IOSDOX"
DEFAULT_LIMIT = 50
MAX_LIMIT = 100
_PROJECT_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


class JiraRouteError(Exception):
    def __init__(self, message: str, status: int = 500):
        super().__init__(message)
        self.status = status


def handle_get_assigned(handler, parsed):
    params = handler.parse_qs(parsed.query)
    project = str(params.get("project", [DEFAULT_PROJECT_KEY])[0] or "").strip().upper()
    site = str(params.get("site", [DEFAULT_JIRA_SITE])[0] or "").strip() or DEFAULT_JIRA_SITE

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
        "project": project,
        "site": site,
        "tickets": tickets,
    })


def fetch_assigned_tickets(*, project: str = DEFAULT_PROJECT_KEY, limit: int = DEFAULT_LIMIT, site: str = DEFAULT_JIRA_SITE):
    jql = build_assigned_jql(project)
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

    return normalize_workitems(data, site=site)


def build_assigned_jql(project: str = DEFAULT_PROJECT_KEY) -> str:
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
        ' AND (statusCategory = "In Progress" OR status = "Selected for Development")'
        " ORDER BY updated DESC"
    )


def normalize_workitems(workitems, *, site: str = DEFAULT_JIRA_SITE):
    tickets = []
    normalized_site = normalize_site(site)
    for item in workitems:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "").strip().upper()
        fields = item.get("fields")
        if not key or not isinstance(fields, dict):
            continue

        title = str(fields.get("summary") or "").strip()
        status = _field_name(fields.get("status"))
        priority = _field_name(fields.get("priority"))
        issue_type = _field_name(fields.get("issuetype"))

        tickets.append({
            "key": key,
            "title": title,
            "status": status,
            "priority": priority,
            "issueType": issue_type,
            "url": f"https://{normalized_site}/browse/{key}",
        })

    return sorted(tickets, key=lambda ticket: ticket["key"].casefold())


def normalize_site(site: str) -> str:
    value = str(site or DEFAULT_JIRA_SITE).strip()
    value = re.sub(r"^https?://", "", value)
    return value.strip("/")


def _field_name(value) -> str:
    if isinstance(value, dict):
        return str(value.get("name") or "").strip()
    return str(value or "").strip()
