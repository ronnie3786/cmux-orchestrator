#!/usr/bin/env python3
"""Watch Ronnie's iOS PR review queue and land each request on the Herdr Active Work board.

Deterministic gh polling (queue list + per-PR enrichment), headless-pi assessment
for new PRs, and board writes through the supported herdr-active-work CLI.
Buzz is bypassed entirely: the board IS the queue.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

REPO = "doximity/iOS-Doximity"
REPO_SLUG = REPO.lower().replace("/", "-")
WORKFLOW = "pr-review-watch"
STAGE = "queued"
ACTOR = "agent:pr-review-watch"

STATE_DIR = Path("~/.local/state/herdr-pr-review-watch").expanduser()
ASSESSOR_AGENT = Path("~/.pi/agent/agents/pr-review-assessor.md").expanduser()
ASSESSOR_MODEL_FALLBACK = "accounts/fireworks/models/deepseek-v4-flash-0731:max"

DEFAULT_INTERVAL = 30
GH_TIMEOUT = 30
ASSESS_TIMEOUT = 180
NEW_PER_PASS = 4
LOCK_STALE_SECONDS = 600

MAX_TITLE = 480
MAX_SUMMARY = 4000

JIRA_KEY_RE = re.compile(r"\b([A-Z][A-Z0-9_]+-\d+)\b")
TEST_FILE_RE = re.compile(r"(Test|Tests)\.swift$")
GRAPHQL_FILE_RE = re.compile(r"\.graphqls?$")
MODEL_RE = re.compile(r"^model:\s*(\S+)", re.MULTILINE)


class WatchError(Exception):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / "runs.log", "a") as handle:
        handle.write(f"{utc_now()} {message}\n")


def run_cmd(cmd: Sequence[str], *, timeout: int, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise WatchError(f"{cmd[0]} failed: {exc}") from exc
    if result.returncode != 0:
        excerpt = (result.stderr or result.stdout or "").strip()[-400:]
        raise WatchError(f"{cmd[0]} exited {result.returncode}: {excerpt}")
    return result.stdout


def run_json(cmd: Sequence[str], *, timeout: int, cwd: Path | None = None) -> Any:
    try:
        return json.loads(run_cmd(cmd, timeout=timeout, cwd=cwd))
    except json.JSONDecodeError as exc:
        raise WatchError(f"{cmd[0]} returned invalid JSON: {exc}") from exc


# --- GitHub discovery -------------------------------------------------------


def gh_me() -> str:
    return run_cmd(["gh", "api", "user", "--jq", ".login"], timeout=GH_TIMEOUT).strip()


def gh_teams() -> set[str]:
    raw = run_cmd(["gh", "api", "user/teams", "--jq", ".[].name"], timeout=GH_TIMEOUT)
    return {line.strip() for line in raw.splitlines() if line.strip()}


def fetch_queue() -> list[dict[str, Any]]:
    out = run_json(
        [
            "gh", "pr", "list",
            "--repo", REPO,
            "--state", "open",
            "--search", "review-requested:@me is:open",
            "--json", "number,title,url,author,isDraft,createdAt,updatedAt,reviewDecision,reviewRequests",
            "--limit", "100",
        ],
        timeout=GH_TIMEOUT,
    )
    if not isinstance(out, list):
        raise WatchError("gh pr list returned a non-list payload")
    return [pr for pr in out if isinstance(pr, dict) and isinstance(pr.get("number"), int)]


def classify_requested(pr: Mapping[str, Any], me: str, teams: set[str]) -> str:
    for request in pr.get("reviewRequests") or []:
        if not isinstance(request, dict):
            continue
        if request.get("login") == me:
            return "direct"
        if request.get("name") in teams:
            return "team"
    return "team"


def review_scope(pr_number: int) -> dict[str, int]:
    query = (
        "query($owner:String!,$repo:String!,$n:Int!){repository(owner:$owner,name:$repo)"
        "{pullRequest(number:$n){files(first:100){totalCount nodes{path additions deletions}}}}}"
    )
    out = run_json(
        ["gh", "api", "graphql", "-f", f"query={query}",
         "-F", "owner=doximity", "-F", "repo=iOS-Doximity", "-F", f"n={pr_number}"],
        timeout=GH_TIMEOUT,
    )
    try:
        files = out["data"]["repository"]["pullRequest"]["files"]
    except (KeyError, TypeError) as exc:
        raise WatchError(f"PR #{pr_number} files query failed: {exc}") from exc
    reviewed = [
        node
        for node in files.get("nodes") or []
        if not is_excluded(str(node.get("path") or ""))
    ]
    return {
        "files": len(reviewed),
        "total_files": int(files.get("totalCount") or 0),
        "additions": sum(int(node.get("additions") or 0) for node in reviewed),
        "deletions": sum(int(node.get("deletions") or 0) for node in reviewed),
    }


def is_excluded(path: str) -> bool:
    return ".g." in path or bool(TEST_FILE_RE.search(path)) or bool(GRAPHQL_FILE_RE.search(path))


def jira_link(pr: Mapping[str, Any]) -> dict[str, str] | None:
    match = JIRA_KEY_RE.search(str(pr.get("title") or ""))
    if not match:
        return None
    key = match.group(1)
    return {"issue_key": key, "url": f"https://doximity.atlassian.net/browse/{key}"}


# --- Board client (supported CLI interface) ---------------------------------


def active_work(*args: str) -> dict[str, Any]:
    env = run_json(
        ["herdr-active-work", "--actor", ACTOR, *args],
        timeout=GH_TIMEOUT,
    )
    if not isinstance(env, dict) or env.get("ok") is not True:
        raise WatchError(f"herdr-active-work {args[0]} failed: {json.dumps(env)[:400]}")
    return env


def board_item_ids() -> set[str]:
    env = active_work("list")
    items = (env.get("data") or {}).get("items") or []
    return {str(item.get("id")) for item in items if isinstance(item, dict)}


def item_id_for(pr_number: int) -> str:
    return f"pr-watch-{REPO_SLUG}-{pr_number}"


def create_item(pr: Mapping[str, Any], requested: str, scope: Mapping[str, int]) -> str:
    number = int(pr["number"])
    author = str((pr.get("author") or {}).get("login") or pr.get("author") or "unknown")
    draft = " (draft)" if pr.get("isDraft") else ""
    title = f"PR #{number} · {str(pr.get('title') or '')[:MAX_TITLE]}{draft}"
    summary = deterministic_summary(pr, author, requested, scope)
    metadata = {
        "pr": {
            "number": number,
            "url": str(pr.get("url") or ""),
            "title": str(pr.get("title") or ""),
            "author": author,
            "repository": REPO,
            "is_draft": bool(pr.get("isDraft")),
        },
        "requested_kind": requested,
        "review_scope": dict(scope),
        "discovered_at": utc_now(),
        "done_label": "reviewed · complete",
    }
    jira = jira_link(pr)
    if jira:
        metadata["jira"] = jira
    env = active_work(
        "create",
        "--id", item_id_for(number),
        "--kind", "task",
        "--title", title,
        "--summary", summary,
        "--workflow", WORKFLOW,
        "--current-stage", STAGE,
        "--next-action", f"Pick a review path for PR #{number}",
        "--metadata-json", json.dumps(metadata, separators=(",", ":")),
    )
    data = env.get("data") or {}
    return str(data.get("id") or item_id_for(number))


def deterministic_summary(
    pr: Mapping[str, Any], author: str, requested: str, scope: Mapping[str, int]
) -> str:
    number = int(pr["number"])
    parts = [
        f"{author} asked for your review ({requested})",
        f"+{scope.get('additions', 0)}/−{scope.get('deletions', 0)} across {scope.get('files', 0)} review files",
    ]
    if pr.get("isDraft"):
        parts.append("draft")
    return f"PR #{number}: " + " · ".join(parts)[:MAX_SUMMARY]


def stage_content(item: str, summary: str, content: Mapping[str, Any]) -> None:
    path = STATE_DIR / "stage-content.json"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as handle:
        json.dump(content, handle, separators=(",", ":"))
    active_work("stage-set", item, "--stage", STAGE, "--summary", summary[:MAX_SUMMARY], "--content-file", str(path))


def update_item(item: str, summary: str, next_action: str) -> None:
    active_work("update", item, "--summary", summary[:MAX_SUMMARY], "--next-action", next_action[:500])


# --- Headless-pi assessment --------------------------------------------------


def assessor_model() -> str:
    try:
        text = ASSESSOR_AGENT.read_text()
        match = MODEL_RE.search(text)
        if match:
            return match.group(1)
    except OSError:
        pass
    return ASSESSOR_MODEL_FALLBACK


def parse_assessment(stdout: str) -> dict[str, Any] | None:
    for line in reversed(str(stdout).splitlines()):
        stripped = line.strip()
        if stripped.startswith("ASSESSMENT_JSON:"):
            try:
                payload = json.loads(stripped[len("ASSESSMENT_JSON:"):].strip())
            except json.JSONDecodeError:
                return None
            if not isinstance(payload, dict):
                return None
            rating = payload.get("rating")
            if not isinstance(rating, int) or not 1 <= rating <= 5:
                return None
            return {
                "rating": rating,
                "cr_estimate": str(payload.get("cr_estimate") or "")[:120],
                "summary": str(payload.get("summary") or "")[:1000],
            }
    return None


def assess_pr(pr: Mapping[str, Any], requested: str, scope: Mapping[str, int]) -> dict[str, Any] | None:
    if not ASSESSOR_AGENT.is_file():
        return None
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    task = STATE_DIR / "assess-task.md"
    payload = {
        "pr": {
            "number": pr.get("number"),
            "title": pr.get("title"),
            "url": pr.get("url"),
            "author": str((pr.get("author") or {}).get("login") or pr.get("author") or "unknown"),
            "repository": REPO,
            "is_draft": bool(pr.get("isDraft")),
        },
        "requested_kind": requested,
        "review_scope": dict(scope),
    }
    with open(task, "w") as handle:
        handle.write(
            "Assess this one PR from Ronnie's review queue. Payload:\n"
            + json.dumps(payload, indent=2)
            + "\nFollow your protocol; the last line of your reply must be the ASSESSMENT_JSON line.\n"
        )
    try:
        stdout = run_cmd(
            [
                "pi", "--no-session", "-p",
                "--mode", "text",
                "--model", assessor_model(),
                "--append-system-prompt", str(ASSESSOR_AGENT),
                f"@{task}",
            ],
            timeout=ASSESS_TIMEOUT,
            cwd=Path.home(),
        )
    except WatchError:
        return None
    return parse_assessment(stdout)


# --- One pass ----------------------------------------------------------------


def pass_once(*, assess: bool = True) -> dict[str, int]:
    counts = {"queue": 0, "new": 0, "assessed": 0, "errors": 0}
    try:
        me = gh_me()
        teams = gh_teams()
        queue = fetch_queue()
    except WatchError as exc:
        log(f"ERROR discovery {exc}")
        counts["errors"] += 1
        return counts
    counts["queue"] = len(queue)

    try:
        known = board_item_ids()
    except WatchError as exc:
        log(f"ERROR board {exc}")
        counts["errors"] += 1
        return counts

    created = 0
    for pr in queue:
        item = item_id_for(int(pr["number"]))
        if item in known:
            continue
        if created >= NEW_PER_PASS:
            break
        created += 1
        counts["new"] += 1
        try:
            requested = classify_requested(pr, me, teams)
            scope = review_scope(int(pr["number"]))
            work_id = create_item(pr, requested, scope)
        except WatchError as exc:
            log(f"ERROR create PR #{pr.get('number')} {exc}")
            counts["errors"] += 1
            continue
        if not assess:
            continue
        assessment = assess_pr(pr, requested, scope)
        if assessment is None:
            log(f"assess skipped/failed PR #{pr.get('number')} (deterministic summary kept)")
            continue
        counts["assessed"] += 1
        try:
            summary = (
                f"{assessment['rating']}/5 · {assessment['cr_estimate']} · {assessment['summary']}"
            )
            stage_content(work_id, assessment["summary"], {"assessment": {**assessment, "assessed_by": "pr-review-assessor"}})
            update_item(work_id, summary, f"Pick a review path for PR #{pr['number']}")
        except WatchError as exc:
            log(f"ERROR assessment write PR #{pr.get('number')} {exc}")
            counts["errors"] += 1
    return counts


# --- Loop / lock ---------------------------------------------------------------


class Lock:
    def __init__(self) -> None:
        self.path = STATE_DIR / "watcher.lock"

    def __enter__(self) -> "Lock":
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        try:
            age = time.time() - self.path.stat().st_mtime
        except OSError:
            age = None
        if age is not None and age < LOCK_STALE_SECONDS:
            sys.exit(0)
        if age is not None:
            self.path.unlink(missing_ok=True)
        try:
            handle = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except OSError:
            sys.exit(0)
        with os.fdopen(handle, "w") as stream:
            stream.write(str(os.getpid()))
        return self

    def __exit__(self, *exc: Any) -> None:
        self.path.unlink(missing_ok=True)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="single pass and exit")
    mode.add_argument("--loop", type=int, metavar="SECONDS", default=None, help="run forever, polling every SECONDS (default 30)")
    parser.add_argument("--no-assess", action="store_true", help="skip headless-pi assessment; keep deterministic summaries")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    interval = args.loop if args.loop is not None else (None if args.once else DEFAULT_INTERVAL)
    if interval is not None and interval < 10:
        print("refusing a poll interval below 10 seconds", file=sys.stderr)
        return 2
    with Lock():
        while True:
            counts = pass_once(assess=not args.no_assess)
            log(
                "pass queue={queue} new={new} assessed={assessed} errors={errors}".format(**counts)
            )
            if interval is None:
                return 0 if counts["errors"] == 0 else 1
            time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main())
