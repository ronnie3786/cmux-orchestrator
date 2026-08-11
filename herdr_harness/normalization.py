"""Forward-compatible composition helpers for Herdr snapshots."""

from __future__ import annotations

import copy
from typing import Any


def _objects(value: Any) -> list[dict]:
    if not isinstance(value, list):
        return []
    return [copy.deepcopy(item) for item in value if isinstance(item, dict)]


def composite_workspaces(snapshot: dict) -> list[dict]:
    """Attach each workspace's tabs, panes, agents, and layouts.

    Every native workspace field and every unknown future field is retained.
    The four relationship arrays are additive and contain untouched copies of
    Herdr's native records.
    """

    workspaces = _objects(snapshot.get("workspaces"))
    tabs = _objects(snapshot.get("tabs"))
    panes = _objects(snapshot.get("panes"))
    agents = _objects(snapshot.get("agents"))
    layouts = _objects(snapshot.get("layouts"))

    for workspace in workspaces:
        workspace_id = workspace.get("workspace_id")
        workspace["tabs"] = [item for item in tabs if item.get("workspace_id") == workspace_id]
        workspace["panes"] = [item for item in panes if item.get("workspace_id") == workspace_id]
        workspace["agents"] = [item for item in agents if item.get("workspace_id") == workspace_id]
        workspace["layouts"] = [item for item in layouts if item.get("workspace_id") == workspace_id]
    return workspaces


def pane_index(snapshot: dict) -> dict[str, dict]:
    """Return panes enriched with matching agent and workspace display data."""

    agents = {
        str(item.get("pane_id")): item
        for item in _objects(snapshot.get("agents"))
        if item.get("pane_id")
    }
    workspaces = {
        str(item.get("workspace_id")): item
        for item in _objects(snapshot.get("workspaces"))
        if item.get("workspace_id")
    }
    tabs = {
        str(item.get("tab_id")): item
        for item in _objects(snapshot.get("tabs"))
        if item.get("tab_id")
    }
    result: dict[str, dict] = {}
    for pane in _objects(snapshot.get("panes")):
        pane_id = pane.get("pane_id")
        if not pane_id:
            continue
        enriched = pane
        agent = agents.get(str(pane_id))
        if agent:
            enriched["agent_info"] = agent
        workspace = workspaces.get(str(pane.get("workspace_id")))
        tab = tabs.get(str(pane.get("tab_id")))
        if workspace:
            enriched["workspace_label"] = workspace.get("label")
        if tab:
            enriched["tab_label"] = tab.get("label")
        result[str(pane_id)] = enriched
    return result
