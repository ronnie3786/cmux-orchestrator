"""Pure parsing and validation for Herdr Active Work workflow configs.

A workflow config is the JSON document that defines one pipeline template: its phases (board
regions) and its ordered stages (skills, checkpoints, and forward-only transitions). This module
has no IO and no database access; herdr_harness.active_work_store applies parsed configs.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Mapping, Optional

from .active_work import ActiveWorkError, bounded_json


_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")


class WorkflowConfigError(ActiveWorkError):
    """A workflow config failed validation. ``path`` looks like ``stages[3].next[0]``."""

    def __init__(self, message: str, *, path: str = "", code: str = "workflow_config_invalid"):
        full_message = f"{path}: {message}" if path else message
        super().__init__(full_message, code=code, status=400)
        self.path = path


@dataclass(frozen=True)
class PhaseConfig:
    """One ordered board region in a workflow."""

    key: str
    title: str


@dataclass(frozen=True)
class StageConfig:
    """One ordered workflow stage and its allowed onward transitions."""

    key: str
    title: str
    phase: str
    skill: str
    checkpoint: str
    sequence: int
    next: tuple[str, ...]


@dataclass(frozen=True)
class WorkflowConfig:
    """A parsed workflow whose raw payload remains the storage source of truth."""

    slug: str
    version: int
    title: str
    description: str
    phases: tuple[PhaseConfig, ...]
    stages: tuple[StageConfig, ...]
    raw: dict[str, Any]


def _reject_unknown(payload: Mapping[str, Any], allowed: set[str], path: str) -> None:
    unknown = sorted(str(key) for key in payload if key not in allowed)
    if unknown:
        raise WorkflowConfigError(f"contains unsupported fields: {', '.join(unknown)}", path=path)


def _require_mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WorkflowConfigError("must be an object", path=path)
    return dict(value)


def _require_text(value: Any, path: str, *, maximum: int, required: bool = True) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        raise WorkflowConfigError("must be a string", path=path)
    candidate = value.strip()
    if required and not candidate:
        raise WorkflowConfigError("is required", path=path)
    if len(candidate) > maximum:
        raise WorkflowConfigError(f"exceeds {maximum} characters", path=path)
    return candidate


def _require_slug(value: Any, path: str) -> str:
    candidate = _require_text(value, path, maximum=64)
    if not _SLUG_RE.fullmatch(candidate):
        raise WorkflowConfigError("must match ^[a-z0-9][a-z0-9-]{1,63}$", path=path)
    return candidate


def parse_workflow_config(payload: Any) -> WorkflowConfig:
    """Validate a submitted workflow config JSON document."""

    bounded = bounded_json(payload, "workflow config", maximum_bytes=64 * 1024)
    body = _require_mapping(bounded, "")
    _reject_unknown(body, {"workflow", "version", "title", "description", "phases", "stages"}, "")
    slug = _require_slug(body.get("workflow"), "workflow")
    version_raw = body.get("version")
    if isinstance(version_raw, bool) or not isinstance(version_raw, int) or version_raw < 1:
        raise WorkflowConfigError("must be a positive integer", path="version")
    version = version_raw
    title = _require_text(body.get("title"), "title", maximum=120)
    description = _require_text(
        body.get("description"), "description", maximum=2000, required=False
    )

    raw_phases = body.get("phases")
    if not isinstance(raw_phases, list) or not 1 <= len(raw_phases) <= 12:
        raise WorkflowConfigError("must be an array with 1 to 12 entries", path="phases")
    phases: list[PhaseConfig] = []
    seen_phase_keys: set[str] = set()
    for index, raw_phase in enumerate(raw_phases):
        phase_path = f"phases[{index}]"
        phase_body = _require_mapping(raw_phase, phase_path)
        _reject_unknown(phase_body, {"key", "title"}, phase_path)
        phase_key = _require_slug(phase_body.get("key"), f"{phase_path}.key")
        if phase_key in seen_phase_keys:
            raise WorkflowConfigError("duplicate phase key", path=f"{phase_path}.key")
        seen_phase_keys.add(phase_key)
        phase_title = _require_text(phase_body.get("title"), f"{phase_path}.title", maximum=120)
        phases.append(PhaseConfig(key=phase_key, title=phase_title))

    raw_stages = body.get("stages")
    if not isinstance(raw_stages, list) or not 2 <= len(raw_stages) <= 32:
        raise WorkflowConfigError("must be an array with 2 to 32 entries", path="stages")
    stage_keys_in_order: list[str] = []
    partials: list[dict[str, Any]] = []
    seen_stage_keys: set[str] = set()
    used_phase_keys: set[str] = set()
    for index, raw_stage in enumerate(raw_stages):
        stage_path = f"stages[{index}]"
        stage_body = _require_mapping(raw_stage, stage_path)
        _reject_unknown(
            stage_body,
            {"key", "title", "phase", "skill", "checkpoint", "next"},
            stage_path,
        )
        stage_key = _require_slug(stage_body.get("key"), f"{stage_path}.key")
        if stage_key in seen_stage_keys:
            raise WorkflowConfigError("duplicate stage key", path=f"{stage_path}.key")
        seen_stage_keys.add(stage_key)
        stage_title = _require_text(stage_body.get("title"), f"{stage_path}.title", maximum=120)
        stage_phase = _require_slug(stage_body.get("phase"), f"{stage_path}.phase")
        if stage_phase not in seen_phase_keys:
            raise WorkflowConfigError("references an undeclared phase", path=f"{stage_path}.phase")
        used_phase_keys.add(stage_phase)
        stage_skill = _require_text(stage_body.get("skill"), f"{stage_path}.skill", maximum=120)
        stage_checkpoint = stage_body.get("checkpoint", "none")
        if stage_checkpoint not in {"none", "human"}:
            raise WorkflowConfigError("must be 'none' or 'human'", path=f"{stage_path}.checkpoint")
        raw_next = stage_body.get("next")
        next_values: Optional[list[str]]
        if raw_next is None:
            next_values = None
        else:
            if not isinstance(raw_next, list):
                raise WorkflowConfigError("must be an array", path=f"{stage_path}.next")
            next_values = []
            for next_index, next_value in enumerate(raw_next):
                next_path = f"{stage_path}.next[{next_index}]"
                if not isinstance(next_value, str):
                    raise WorkflowConfigError("must be a string", path=next_path)
                next_values.append(next_value)
        stage_keys_in_order.append(stage_key)
        partials.append({"key": stage_key, "title": stage_title, "phase": stage_phase,
                         "skill": stage_skill, "checkpoint": stage_checkpoint, "next": next_values})

    unused_phases = seen_phase_keys - used_phase_keys
    if unused_phases:
        raise WorkflowConfigError(
            f"unused phases: {', '.join(sorted(unused_phases))}", path="phases"
        )
    sequence_by_key = {key: index + 1 for index, key in enumerate(stage_keys_in_order)}
    last_key = stage_keys_in_order[-1]
    stages: list[StageConfig] = []
    for index, partial in enumerate(partials):
        stage_path = f"stages[{index}]"
        sequence = index + 1
        raw_next = partial["next"]
        if raw_next is None:
            resolved_next: tuple[str, ...] = (
                () if index == len(partials) - 1 else (stage_keys_in_order[index + 1],)
            )
        else:
            resolved: list[str] = []
            for next_index, next_key in enumerate(raw_next):
                next_path = f"{stage_path}.next[{next_index}]"
                if next_key not in sequence_by_key:
                    raise WorkflowConfigError("references an undeclared stage", path=next_path)
                if sequence_by_key[next_key] <= sequence:
                    raise WorkflowConfigError(
                        "must reference a stage later in the sequence", path=next_path
                    )
                resolved.append(next_key)
            resolved_next = tuple(resolved)
            if partial["key"] == last_key and resolved_next:
                raise WorkflowConfigError(
                    "the final stage must be terminal", path=f"{stage_path}.next"
                )
        stages.append(
            StageConfig(
                key=partial["key"],
                title=partial["title"],
                phase=partial["phase"],
                skill=partial["skill"],
                checkpoint=partial["checkpoint"],
                sequence=sequence,
                next=resolved_next,
            )
        )
    return WorkflowConfig(
        slug=slug,
        version=version,
        title=title,
        description=description,
        phases=tuple(phases),
        stages=tuple(stages),
        raw=body,
    )
