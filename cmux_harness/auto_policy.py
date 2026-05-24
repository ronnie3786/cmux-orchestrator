from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import storage

AUTO_POLICY_PROVIDER = "fireworks"
AUTO_POLICY_MODEL = os.environ.get("CMUX_AUTO_POLICY_MODEL") or os.environ.get(
    "ORCHESTRATOR_V2_AGENT_MODEL",
    "accounts/fireworks/models/minimax-m2p7",
)
INPUT_COST_PER_MILLION = 0.30
OUTPUT_COST_PER_MILLION = 1.20
AUTO_POLICY_LOG_LIMIT = 1000

REPO_ROOT = Path(__file__).resolve().parent.parent
NODE_POLICY_CLI = REPO_ROOT / "agent" / "orchestrator-v2" / "src" / "autoApprovalPolicyCli.js"


def fireworks_configured() -> bool:
    if os.environ.get("FIREWORKS_API_KEY"):
        return True
    env_path = REPO_ROOT / ".env.local"
    try:
        for raw in env_path.read_text().splitlines():
            line = raw.strip()
            if line.startswith("FIREWORKS_API_KEY=") and line.split("=", 1)[1].strip():
                return True
    except OSError:
        return False
    return False


def estimate_cost(input_tokens: int | None, output_tokens: int | None) -> float:
    input_count = max(0, int(input_tokens or 0))
    output_count = max(0, int(output_tokens or 0))
    return (
        (input_count / 1_000_000.0) * INPUT_COST_PER_MILLION
        + (output_count / 1_000_000.0) * OUTPUT_COST_PER_MILLION
    )


def run_auto_policy(payload: dict[str, Any], timeout: int = 30) -> dict[str, Any]:
    node = shutil.which("node")
    if not node:
        return _error("node is not available on PATH", "node_missing")
    if not NODE_POLICY_CLI.exists():
        return _error(f"auto policy CLI not found: {NODE_POLICY_CLI}", "cli_missing")

    started = time.monotonic()
    env = os.environ.copy()
    env.setdefault("CMUX_AUTO_POLICY_MODEL", AUTO_POLICY_MODEL)
    try:
        result = subprocess.run(
            [node, str(NODE_POLICY_CLI)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return _error(f"auto policy timed out after {timeout}s", "timeout", started)
    except OSError as exc:
        return _error(str(exc), "subprocess_error", started)

    raw = (result.stdout or "").strip()
    try:
        parsed = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return _error("auto policy returned invalid JSON", "invalid_json", started)

    if not isinstance(parsed, dict):
        return _error("auto policy returned a non-object response", "invalid_response", started)

    parsed.setdefault("latencyMs", int((time.monotonic() - started) * 1000))
    if result.returncode != 0 and parsed.get("ok") is not True:
        parsed.setdefault("ok", False)
        parsed.setdefault("type", "model_error")
    return parsed


def normalize_policy_result(result: dict[str, Any] | None, *, auto_mode: str, threshold: int) -> dict[str, Any] | None:
    if not isinstance(result, dict) or result.get("ok") is not True:
        return None

    policy = result.get("policy")
    if not isinstance(policy, dict):
        return None

    action = _clean_enum(policy.get("action"), {"approve", "submit", "alert", "ignore"}, "alert")
    submit = _clean_enum(policy.get("submit"), {"enter", "y", "yes", "1", "2", "3", "4", "none"}, "none")
    reason = str(policy.get("reason") or "").strip()[:240]
    terminal_state = _clean_enum(
        policy.get("terminalState"),
        {"running", "idle_prompt", "approval_prompt", "question_prompt", "completed", "unknown"},
        "unknown",
    )
    try:
        confidence = float(policy.get("confidence") or 0)
    except (TypeError, ValueError):
        confidence = 0.0
    confidence = max(0.0, min(1.0, confidence))
    try:
        level = int(policy.get("level")) if policy.get("level") is not None else None
    except (TypeError, ValueError):
        level = None
    if level is not None and not 1 <= level <= 5:
        level = None

    approval_needed = bool(policy.get("approvalNeeded"))
    super_auto = str(auto_mode or "").lower() == "super"
    if not approval_needed:
        return {
            "approvalNeeded": False,
            "terminalState": terminal_state,
            "action": "ignore",
            "submit": "none",
            "level": level,
            "confidence": confidence,
            "reason": reason or "No approval or continuation prompt is visible.",
        }

    if action in {"approve", "submit"} and submit == "none":
        action = "alert"
        reason = reason or "Model found an approval prompt but no safe submit key."

    if action in {"approve", "submit"} and not super_auto:
        if level is None or level > int(threshold or 3):
            action = "alert"
            submit = "none"
            reason = reason or f"Level {level or 5} is above auto-approval threshold {threshold}."
        elif confidence < 0.85:
            action = "alert"
            submit = "none"
            reason = reason or "Low confidence auto-approval decision."

    if super_auto and action == "alert" and submit != "none":
        action = "approve"

    return {
        "approvalNeeded": True,
        "terminalState": terminal_state,
        "action": action,
        "submit": submit,
        "level": level,
        "confidence": confidence,
        "reason": reason or "Auto policy decision.",
    }


def record_policy_usage(entry: dict[str, Any]) -> dict[str, Any]:
    usage = entry.get("usage") if isinstance(entry.get("usage"), dict) else {}
    input_tokens = _int_or_zero(usage.get("inputTokens"))
    output_tokens = _int_or_zero(usage.get("outputTokens"))
    total_tokens = _int_or_zero(usage.get("totalTokens")) or input_tokens + output_tokens
    estimated_cost = estimate_cost(input_tokens, output_tokens)
    stored = {
        "timestamp": entry.get("timestamp") or _utc_now(),
        "provider": entry.get("provider") or AUTO_POLICY_PROVIDER,
        "model": entry.get("model") or AUTO_POLICY_MODEL,
        "workspace": entry.get("workspace"),
        "workspaceName": entry.get("workspaceName") or "",
        "workspaceUuid": entry.get("workspaceUuid") or "",
        "surfaceId": entry.get("surfaceId") or "",
        "autoMode": entry.get("autoMode") or "",
        "screenFingerprint": entry.get("screenFingerprint") or "",
        "approvalThreshold": entry.get("approvalThreshold"),
        "terminalState": entry.get("terminalState") or "",
        "approvalNeeded": bool(entry.get("approvalNeeded")),
        "action": entry.get("action") or "",
        "submit": entry.get("submit") or "",
        "severityLevel": entry.get("severityLevel"),
        "confidence": entry.get("confidence"),
        "reason": str(entry.get("reason") or "")[:240],
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
        "totalTokens": total_tokens,
        "estimatedCostUSD": estimated_cost,
        "latencyMs": _int_or_zero(entry.get("latencyMs")),
        "promptChars": _int_or_zero(entry.get("promptChars")),
        "ok": bool(entry.get("ok", True)),
        "error": str(entry.get("error") or "")[:240],
    }
    _append_jsonl(storage.AUTO_POLICY_COST_LOG, stored)
    return stored


def read_cost_entries(limit: int = 200) -> list[dict[str, Any]]:
    count = max(1, min(int(limit or 200), AUTO_POLICY_LOG_LIMIT))
    if not storage.AUTO_POLICY_COST_LOG.exists():
        return []
    entries: list[dict[str, Any]] = []
    try:
        with open(storage.AUTO_POLICY_COST_LOG, "r") as f:
            lines = f.readlines()[-count:]
    except OSError:
        return []
    for line in lines:
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            entries.append(parsed)
    return list(reversed(entries))


def cost_dashboard(limit: int = 200) -> dict[str, Any]:
    entries = read_cost_entries(limit)
    totals = {
        "calls": len(entries),
        "inputTokens": sum(_int_or_zero(item.get("inputTokens")) for item in entries),
        "outputTokens": sum(_int_or_zero(item.get("outputTokens")) for item in entries),
        "totalTokens": sum(_int_or_zero(item.get("totalTokens")) for item in entries),
        "estimatedCostUSD": sum(float(item.get("estimatedCostUSD") or 0.0) for item in entries),
        "approvals": sum(1 for item in entries if item.get("action") in {"approve", "submit"}),
        "alerts": sum(1 for item in entries if item.get("action") == "alert"),
        "ignored": sum(1 for item in entries if item.get("action") == "ignore"),
        "errors": sum(1 for item in entries if not item.get("ok", True)),
    }
    return {
        "ok": True,
        "provider": AUTO_POLICY_PROVIDER,
        "model": AUTO_POLICY_MODEL,
        "rates": {
            "inputPerMillionUSD": INPUT_COST_PER_MILLION,
            "outputPerMillionUSD": OUTPUT_COST_PER_MILLION,
        },
        "totals": totals,
        "entries": entries,
    }


def _error(message: str, error_type: str, started: float | None = None) -> dict[str, Any]:
    return {
        "ok": False,
        "type": error_type,
        "error": message,
        "provider": AUTO_POLICY_PROVIDER,
        "model": AUTO_POLICY_MODEL,
        "usage": {"inputTokens": 0, "outputTokens": 0, "totalTokens": 0},
        "latencyMs": int((time.monotonic() - started) * 1000) if started else 0,
    }


def _append_jsonl(path: Path, entry: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clean_enum(value: Any, allowed: set[str], default: str) -> str:
    normalized = str(value or "").strip().lower()
    return normalized if normalized in allowed else default


def _int_or_zero(value: Any) -> int:
    try:
        number = int(value or 0)
    except (TypeError, ValueError):
        return 0
    return max(0, number)
