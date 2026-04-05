from __future__ import annotations

import time

from .claude_cli import run_haiku


def _latency_ms(start: float) -> int:
    return int(round((time.monotonic() - start) * 1000))


def build_approval_prompt(screen_text: str, spec_text: str | None = None) -> str:
    parts = [
        "You are an approval classifier for an AI coding agent.",
        "",
    ]
    if spec_text is not None:
        parts.extend([
            "Task context:",
            spec_text,
            "",
        ])
    parts.extend([
        "Terminal screen text:",
        screen_text,
        "",
        "Classify this request as exactly one of:",
        "- APPROVE: Routine actions clearly aligned with the task, including file reads, file writes or edits, bash commands for building or testing, standard Yes/No permission prompts, and tool use confirmations.",
        "- ESCALATE: Needs human judgment, including design decisions, multi-option selections where the right choice is not obvious, destructive actions like deleting files or dropping tables, anything ambiguous or outside the task scope, and multi-checkbox selections.",
        "",
        'Respond with JSON: {"decision": "APPROVE" or "ESCALATE", "reason": "brief explanation"}',
    ])
    return "\n".join(parts)


def classify_approval(
    screen_text: str,
    spec_text: str | None = None,
    timeout: int = 15,
) -> dict:
    prompt = build_approval_prompt(screen_text, spec_text=spec_text)
    start = time.monotonic()
    try:
        result = run_haiku(prompt, timeout=timeout)
    except Exception as exc:
        latency_ms = _latency_ms(start)
        return {
            "decision": "ERROR",
            "reason": str(exc),
            "model": "haiku",
            "latency_ms": latency_ms,
        }

    latency_ms = _latency_ms(start)

    if isinstance(result, dict):
        decision = result.get("decision")
        reason = result.get("reason")
        if decision in {"APPROVE", "ESCALATE"} and isinstance(reason, str):
            return {
                "decision": decision,
                "reason": reason,
                "model": "haiku",
                "latency_ms": latency_ms,
            }
        if "error" in result:
            return {
                "decision": "ERROR",
                "reason": str(result.get("error", "unknown error")),
                "model": "haiku",
                "latency_ms": latency_ms,
            }

    return {
        "decision": "ESCALATE",
        "reason": "Unexpected Haiku response format",
        "model": "haiku",
        "latency_ms": latency_ms,
    }


def should_auto_approve(classification: dict) -> bool:
    return classification.get("decision") == "APPROVE"
