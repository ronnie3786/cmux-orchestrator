#!/usr/bin/env python3
"""Create isolated, restorative Herdr workspaces and optional real agents.

The script never closes existing workspaces. It reuses only workspaces whose
label and pane paths prove they belong to the selected fixture root, and it
repairs missing fixture panes without deleting extra user state.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import time
from pathlib import Path
from typing import Optional

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from herdr_harness.client import HerdrClient, HerdrClientError  # noqa: E402


DEMO_WORKSPACES = (
    {
        "label": "Herdr Command Center",
        "folder": "command-center",
        "accent": "36",
        "message": "Live agent overview and triage queue",
    },
    {
        "label": "Herdr Feature Lab",
        "folder": "feature-lab",
        "accent": "35",
        "message": "Implementation, tests, and working notes",
    },
    {
        "label": "Herdr Review Deck",
        "folder": "review-deck",
        "accent": "33",
        "message": "Review findings and release readiness",
    },
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create Herdr Harness demo data")
    parser.add_argument("--session", default=os.environ.get("HERDR_SESSION", "herdr-ios-fixtures"))
    parser.add_argument("--socket", dest="socket_path", default=os.environ.get("HERDR_SOCKET_PATH"))
    parser.add_argument("--root", type=Path, default=Path("/private/tmp/herdr-harness-demo"))
    parser.add_argument(
        "--start-agents",
        action="store_true",
        help="Start real agents in fixture-owned demo panes",
    )
    parser.add_argument("--agent-kind", default="codex")
    parser.add_argument(
        "--agent-count",
        type=int,
        default=2,
        help=f"Number of real agents to start, from 0 to {len(DEMO_WORKSPACES)}",
    )
    parser.add_argument("--prompt", default="Review this demo workspace and wait for further instructions.")
    parser.add_argument("--json", action="store_true", help="Print only the result JSON")
    return parser


def _prepare_directories(root: Path) -> dict[str, Path]:
    paths: dict[str, Path] = {}
    for item in DEMO_WORKSPACES:
        path = (root / item["folder"]).resolve()
        brief = path / "HERDR_DEMO.md"
        path.mkdir(parents=True, exist_ok=True)
        if brief.exists():
            contents = brief.read_text(encoding="utf-8", errors="replace")
            if "disposable test data for Herdr Harness" not in contents:
                raise ValueError(f"fixture marker is not owned by Herdr Harness: {brief}")
        else:
            if any(path.iterdir()):
                raise ValueError(
                    f"refusing to claim non-empty directory without a Herdr Harness marker: {path}"
                )
            brief.write_text(
                f"# {item['label']}\n\n{item['message']}.\n\n"
                "This directory is disposable test data for Herdr Harness.\n",
                encoding="utf-8",
            )
        paths[item["label"]] = path
    return paths


def _path_is_within(value: object, expected: Path) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        candidate = Path(value).expanduser().resolve()
    except (OSError, RuntimeError):
        return False
    return candidate == expected or expected in candidate.parents


def _workspace_panes(snapshot: dict, workspace_id: str) -> list[dict]:
    return sorted(
        [
            pane
            for pane in snapshot.get("panes", [])
            if isinstance(pane, dict) and pane.get("workspace_id") == workspace_id
        ],
        key=lambda pane: str(pane.get("pane_id") or ""),
    )


def _owned_workspace(snapshot: dict, label: str, expected: Path) -> Optional[dict]:
    candidates = [
        workspace
        for workspace in snapshot.get("workspaces", [])
        if isinstance(workspace, dict) and workspace.get("label") == label
    ]
    if not candidates:
        return None
    owned = []
    for workspace in candidates:
        workspace_id = str(workspace.get("workspace_id") or "")
        worktree = workspace.get("worktree") if isinstance(workspace.get("worktree"), dict) else {}
        path_match = _path_is_within(worktree.get("checkout_path"), expected)
        path_match = path_match or any(
            _path_is_within(pane.get("cwd"), expected)
            or _path_is_within(pane.get("foreground_cwd"), expected)
            for pane in _workspace_panes(snapshot, workspace_id)
        )
        if path_match:
            owned.append(workspace)
    if len(owned) == 1:
        return owned[0]
    if len(owned) > 1:
        raise ValueError(f"multiple fixture-owned workspaces use label {label!r}; resolve the duplicate first")
    raise ValueError(
        f"workspace label {label!r} already exists outside {expected}; refusing to modify it"
    )


def _pane_from_result(result: dict) -> dict:
    pane = result.get("pane") or result.get("root_pane")
    if not isinstance(pane, dict) or not pane.get("pane_id"):
        raise HerdrClientError("Herdr creation response did not contain a pane")
    return pane


def _write_banner(client: HerdrClient, pane_id: str, accent: str, message: str) -> None:
    command = (
        f"printf '\\033[{accent}mHERDR HARNESS\\033[0m\\n"
        f"{message}\\nPane: {pane_id}\\n'"
    )
    client.request("pane.send_input", {"pane_id": pane_id, "text": command, "keys": ["enter"]})


def _wait_for_agent(client: HerdrClient, name: str, *, timeout_seconds: float = 15.0) -> dict:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        snapshot = client.snapshot()
        agent = next(
            (
                item
                for item in snapshot.get("agents", [])
                if isinstance(item, dict) and item.get("name") == name
            ),
            None,
        )
        if agent and agent.get("interactive_ready"):
            return agent
        time.sleep(0.2)
    raise HerdrClientError(f"agent {name} did not become interactive before the fixture timeout")


def _ensure_three_panes(
    client: HerdrClient,
    workspace: dict,
    *,
    path: Path,
    accent: str,
) -> dict:
    workspace_id = str(workspace.get("workspace_id") or "")
    if not workspace_id:
        raise HerdrClientError("Herdr workspace response did not contain a workspace ID")
    panes = _workspace_panes(client.snapshot(), workspace_id)
    if not panes:
        raise HerdrClientError(
            f"fixture workspace {workspace_id} has no root pane; close it manually and rerun the fixture"
        )
    repaired: list[dict] = []
    while len(panes) < 3:
        root_id = str(panes[0]["pane_id"])
        direction = "right" if len(panes) == 1 else "down"
        split = client.request(
            "pane.split",
            {
                "target_pane_id": root_id,
                "direction": direction,
                "ratio": 0.52 if direction == "right" else 0.60,
                "cwd": str(path),
                "focus": False,
            },
        )
        pane = _pane_from_result(split)
        _write_banner(
            client,
            str(pane["pane_id"]),
            accent,
            "Agent session ready" if len(panes) == 1 else "Logs and test output",
        )
        panes.append(pane)
        repaired.append(pane)
    return {
        "workspace": workspace,
        "paneIds": [str(pane.get("pane_id")) for pane in panes],
        "repairedPanes": repaired,
        "warning": "Extra panes were preserved" if len(panes) > 3 else None,
    }


def create_demo(args: argparse.Namespace) -> dict:
    if not 0 <= args.agent_count <= len(DEMO_WORKSPACES):
        raise ValueError(f"agent-count must be between 0 and {len(DEMO_WORKSPACES)}")
    paths = _prepare_directories(args.root)
    client = HerdrClient(socket_path=args.socket_path, session=args.session)
    snapshot = client.snapshot()
    created: list[dict] = []
    reusable: list[dict] = []
    repaired: list[dict] = []
    owned_workspace_ids: set[str] = set()

    for item in DEMO_WORKSPACES:
        label = item["label"]
        workspace = _owned_workspace(snapshot, label, paths[label])
        if workspace is None:
            workspace_result = client.request(
                "workspace.create",
                {
                    "cwd": str(paths[label]),
                    "label": label,
                    "focus": False,
                    "env": {"HERDR_HARNESS_DEMO": "1"},
                },
            )
            workspace = workspace_result.get("workspace") or {}
            root_pane = _pane_from_result(workspace_result)
            _write_banner(client, str(root_pane["pane_id"]), item["accent"], item["message"])
            created.append({"workspace": workspace, "rootPane": root_pane})
        else:
            reusable.append(workspace)

        topology = _ensure_three_panes(
            client,
            workspace,
            path=paths[label],
            accent=item["accent"],
        )
        if topology["repairedPanes"] or topology["warning"]:
            repaired.append(topology)
        owned_workspace_ids.add(str(workspace.get("workspace_id")))
        snapshot = client.snapshot()
    agents: list[dict] = []
    agent_failures: list[dict] = []
    if args.start_agents:
        topology = client.snapshot()
        workspace_by_id = {
            str(item.get("workspace_id")): item
            for item in topology.get("workspaces", [])
            if isinstance(item, dict) and str(item.get("workspace_id")) in owned_workspace_ids
        }
        active_agents = [item for item in topology.get("agents", []) if isinstance(item, dict)]
        reusable_agents = [
            item
            for item in active_agents
            if str(item.get("name") or "").startswith("demo_")
            and any(
                pane.get("pane_id") == item.get("pane_id")
                for workspace_id in owned_workspace_ids
                for pane in _workspace_panes(topology, workspace_id)
            )
        ]
        occupied_panes = {str(item.get("pane_id")) for item in active_agents if item.get("pane_id")}
        used_names = {str(item.get("name")) for item in active_agents if item.get("name")}
        agent_candidates = []
        ordered_workspace_ids = [
            str(workspace.get("workspace_id"))
            for workspace in topology.get("workspaces", [])
            if isinstance(workspace, dict) and str(workspace.get("workspace_id")) in owned_workspace_ids
        ]
        for index, workspace_id in enumerate(ordered_workspace_ids):
            workspace = workspace_by_id.get(workspace_id)
            if not workspace:
                continue
            panes = [
                pane
                for pane in topology.get("panes", [])
                if isinstance(pane, dict)
                and pane.get("workspace_id") == workspace.get("workspace_id")
                and str(pane.get("pane_id")) not in occupied_panes
            ]
            if panes:
                # The second pane is the intended agent position in newly
                # created fixtures, while the fallback also repairs partial
                # or older demo topologies.
                selected = panes[1] if len(panes) > 1 else panes[0]
                agent_candidates.append({"index": index, "workspace": workspace, "pane": selected})

        agents.extend(reusable_agents[: args.agent_count])
        remaining_agent_count = max(0, args.agent_count - len(agents))
        for candidate in agent_candidates[:remaining_agent_count]:
            pane_id = str(candidate["pane"]["pane_id"])
            base_name = f"demo_{candidate['index'] + 1}"
            agent_name = base_name
            suffix = 2
            while agent_name in used_names:
                agent_name = f"{base_name}_{suffix}"
                suffix += 1
            used_names.add(agent_name)
            try:
                started = client.request(
                    "agent.start",
                    {
                        "name": agent_name,
                        "kind": args.agent_kind,
                        "pane_id": pane_id,
                        "args": [],
                        "timeout_ms": 60000,
                    },
                )
            except HerdrClientError as exc:
                agent_failures.append(
                    {"stage": "start", "name": agent_name, "paneId": pane_id, "error": str(exc)}
                )
                continue
            agents.append(started.get("agent") or started)
            try:
                active_agent = _wait_for_agent(client, agent_name)
                agents[-1] = active_agent
                if args.prompt:
                    client.request("agent.prompt", {"target": agent_name, "text": args.prompt})
            except HerdrClientError as exc:
                agent_failures.append(
                    {
                        "stage": "readiness_or_prompt",
                        "name": agent_name,
                        "paneId": pane_id,
                        "error": str(exc),
                    }
                )

    final_snapshot = client.snapshot()
    fixture_workspace_ids = sorted(owned_workspace_ids)
    fixture_pane_count = sum(
        1
        for pane in final_snapshot.get("panes", [])
        if isinstance(pane, dict) and str(pane.get("workspace_id")) in owned_workspace_ids
    )
    return {
        "ok": not agent_failures,
        "session": client.session,
        "socketPath": client.socket_path,
        "root": str(args.root.resolve()),
        "created": created,
        "reused": reusable,
        "repaired": repaired,
        "agentsStarted": agents,
        "agentFailures": agent_failures,
        "fixtureWorkspaceIds": fixture_workspace_ids,
        "fixtureWorkspaceCount": len(fixture_workspace_ids),
        "fixturePaneCount": fixture_pane_count,
        "snapshot": final_snapshot,
    }


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = create_demo(args)
    except (HerdrClientError, OSError, ValueError) as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, separators=(",", ":")))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    else:
        print(f"Herdr demo ready in {result['root']}")
        print(f"Created {len(result['created'])} workspace(s), reused {len(result['reused'])}.")
        print(f"Repaired {len(result['repaired'])} partial workspace(s).")
        print(
            "Fixture topology: "
            f"{result['fixtureWorkspaceCount']} workspace(s), "
            f"{result['fixturePaneCount']} pane(s)."
        )
        print(f"Started {len(result['agentsStarted'])} real agent session(s).")
        if result["agentFailures"]:
            print("One or more agent steps failed. Active agent details are included above.", file=sys.stderr)
            print(
                f"Recovery: herdr session stop {shlex.quote(result['session'])} --json",
                file=sys.stderr,
            )
        run_environment = (
            f"HERDR_SOCKET_PATH={shlex.quote(result['socketPath'])}"
            if args.socket_path
            else f"HERDR_SESSION={shlex.quote(result['session'])}"
        )
        print(f"Run: {run_environment} python3 herdr_dashboard.py --no-browser")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
