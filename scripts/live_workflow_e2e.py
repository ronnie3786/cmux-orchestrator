#!/usr/bin/env python3
"""Live end-to-end smoke test for the web-first Workflow Orchestrator.

This intentionally uses the public HTTP API that the lightweight web app uses.
It proves the visible Hybrid B flow without depending on private Python helpers:
idea -> pre-flight -> launch objective -> review-ready -> accepted done -> cleanup.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class ApiError(RuntimeError):
    pass


class Client:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            self.base_url + path,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            raise ApiError(f"{method} {path} failed with HTTP {exc.code}: {raw}") from exc
        except urllib.error.URLError as exc:
            raise ApiError(f"{method} {path} failed: {exc}") from exc
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ApiError(f"{method} {path} returned non-JSON: {raw[:300]}") from exc
        if data.get("ok") is False:
            raise ApiError(f"{method} {path} returned ok=false: {data}")
        return data

    def get(self, path: str) -> dict[str, Any]:
        return self.request("GET", path)

    def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self.request("POST", path, payload)

    def patch(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self.request("PATCH", path, payload)

    def delete(self, path: str) -> dict[str, Any]:
        return self.request("DELETE", path)


def assert_true(condition: Any, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def lane(payload: dict[str, Any], lane_id: str) -> dict[str, Any]:
    lanes = {item.get("id"): item for item in payload.get("lanes", [])}
    assert_true(lane_id in lanes, f"missing lane {lane_id}; got {list(lanes)}")
    return lanes[lane_id]


def cards(payload: dict[str, Any], lane_id: str) -> list[dict[str, Any]]:
    return lane(payload, lane_id).get("cards", [])


def create_git_repo(root: Path) -> Path:
    repo = root / "repo"
    repo.mkdir(parents=True)
    subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True, text=True)
    subprocess.run(
        ["git", "-c", "user.name=Workflow E2E", "-c", "user.email=workflow-e2e@example.test", "commit", "--allow-empty", "-m", "init"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return repo


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a live Workflow Orchestrator E2E smoke test.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8791", help="Harness base URL")
    parser.add_argument("--keep-artifacts", action="store_true", help="Do not delete created API records or scratch repo")
    args = parser.parse_args()

    client = Client(args.base_url)
    created: dict[str, str | None] = {"idea": None, "preflight": None, "objective": None}
    scratch = Path(tempfile.mkdtemp(prefix="cmux-workflow-e2e-"))

    try:
        repo = create_git_repo(scratch)
        page = urllib.request.urlopen(args.base_url.rstrip("/") + "/workflow-orchestrator", timeout=20)
        assert_true(page.status == 200, "workflow page did not return 200")

        start = client.get("/api/command-center")
        print(f"start summary: {json.dumps(start.get('summary', {}), sort_keys=True)}")

        idea = client.post("/api/ideas", {
            "title": "E2E web objective handoff",
            "summary": "Prove the web-first path from intake to accepted completion.",
        }).get("idea")
        assert_true(idea and idea.get("id"), "idea create did not return idea.id")
        created["idea"] = idea["id"]

        preflight = client.post("/api/preflights", {
            "sourceType": "idea",
            "sourceId": idea["id"],
            "title": idea["title"],
            "summary": idea["summary"],
        }).get("preflight")
        assert_true(preflight and preflight.get("id"), "preflight create did not return preflight.id")
        created["preflight"] = preflight["id"]

        required_context = [
            dict(item, state="resolved", reason="Verified by live web E2E smoke.")
            if item.get("id") == "open_questions" else item
            for item in preflight.get("requiredContext", [])
        ]
        preflight = client.patch(f"/api/preflights/{urllib.parse.quote(preflight['id'])}", {
            "projectDir": str(repo),
            "baseBranch": "main",
            "requiredContext": required_context,
        }).get("preflight")
        assert_true(preflight.get("launchReady"), f"preflight was not launch ready: {preflight.get('missingRequirements')}")

        objective = client.post(f"/api/preflights/{urllib.parse.quote(preflight['id'])}/launch-objective", {}).get("objective")
        assert_true(objective and objective.get("id"), "launch did not return objective.id")
        created["objective"] = objective["id"]

        running = client.get("/api/command-center")
        running_cards = [card for card in cards(running, "running") if card.get("id") == objective["id"]]
        assert_true(len(running_cards) == 1, "launched objective did not appear exactly once in Running")
        assert_true(running_cards[0].get("sourcePreflightId") == preflight["id"], "running card missing source preflight")

        client.post(f"/api/objectives/{urllib.parse.quote(objective['id'])}/check-in", {"summary": "Live E2E check-in before review handoff."})
        client.patch(f"/api/objectives/{urllib.parse.quote(objective['id'])}", {
            "status": "review",
            "summary": "Ready for Ronnie to inspect from the web E2E flow.",
        })
        review = client.get("/api/command-center")
        assert_true(any(card.get("id") == objective["id"] for card in cards(review, "review")), "objective did not move to Review")
        briefing = client.get("/api/briefing")
        assert_true(briefing.get("counts", {}).get("reviewReady", 0) >= 1, "briefing did not count review-ready objective")

        client.patch(f"/api/objectives/{urllib.parse.quote(objective['id'])}", {
            "status": "completed",
            "summary": "Reviewed and accepted by the live web E2E flow.",
        })
        done = client.get("/api/command-center")
        assert_true(any(card.get("id") == objective["id"] for card in cards(done, "done")), "objective did not move to Done")
        assert_true(done.get("summary", {}).get("completed", 0) >= 1, "completed count did not increment")

        print("verified flow: idea -> preflight -> launch -> running -> review -> done")
        print(f"created ids: {json.dumps(created, sort_keys=True)}")
        return 0
    finally:
        if args.keep_artifacts:
            print(f"kept scratch repo: {scratch}")
            print(f"kept API records: {json.dumps(created, sort_keys=True)}")
        else:
            for key, path_template in (
                ("objective", "/api/objectives/{id}"),
                ("preflight", "/api/preflights/{id}"),
                ("idea", "/api/ideas/{id}"),
            ):
                item_id = created.get(key)
                if item_id:
                    try:
                        client.delete(path_template.format(id=urllib.parse.quote(item_id)))
                    except Exception as exc:  # best-effort cleanup should not hide test result
                        print(f"cleanup warning for {key} {item_id}: {exc}", file=sys.stderr)
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"live workflow E2E failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
