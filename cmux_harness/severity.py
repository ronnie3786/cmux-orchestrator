"""Tool severity classification for Claude Code PreToolUse hooks.

Replaces the old polling-based approval system (detection.py + approval.py)
with a deterministic, hook-driven severity classifier.  Each tool use is
assigned a level 1-5 and auto-approved or escalated based on a configurable
threshold.

Levels:
    1 — Read-only project access (Read, Glob, Grep, LSP, …)
    2 — Write/edit files, safe Bash (build, test, ls, cat, …)
    3 — External API calls to known-safe services (WebFetch, GitHub MCP, …)
    4 — Ambiguous / needs human judgment (AskUserQuestion, unknown MCP, …)
    5 — Destructive / dangerous (rm -rf, force push, DROP TABLE, …)
"""

from __future__ import annotations

import re
import time

from .claude_cli import run_haiku


# ── Level maps (fast-path, no LLM) ──────────────────────────────────────

LEVEL_1_TOOLS: set[str] = {
    "Read", "Glob", "Grep", "LSP", "ListDir", "LS", "Search", "Open", "Find",
    "TodoRead", "NotebookRead", "TaskGet", "TaskList", "TaskOutput",
}

LEVEL_2_TOOLS: set[str] = {
    "Edit", "Write", "MultiEdit", "NotebookEdit", "TodoWrite",
}

LEVEL_3_TOOLS: set[str] = {
    "WebFetch", "WebSearch", "Fetch",
}

LEVEL_4_TOOLS: set[str] = {
    "AskUserQuestion", "Agent", "TaskCreate",
}

# MCP tool name fragments considered safe at level 3
_SAFE_MCP_FRAGMENTS: set[str] = {
    "jira", "github", "slack", "figma", "glean", "linear",
    "google_calendar", "atlassian",
}

# ── Destructive Bash patterns ────────────────────────────────────────────

DESTRUCTIVE_BASH_PATTERNS: list[re.Pattern] = [
    re.compile(p, re.IGNORECASE)
    for p in [
        r"\brm\s+(-\w*[rf]|-\w*[rf]\w*)\b",         # rm -rf, rm -f, etc.
        r"\bgit\s+push\s+.*--force\b",                # git push --force
        r"\bgit\s+push\s+-f\b",                       # git push -f
        r"\bgit\s+reset\s+--hard\b",                  # git reset --hard
        r"\bgit\s+clean\s+-[fd]",                     # git clean -f / -fd
        r"\bgit\s+checkout\s+\.\s*$",                 # git checkout .
        r"\bgit\s+restore\s+\.\s*$",                  # git restore .
        r"\bDROP\s+(TABLE|DATABASE)\b",                # DROP TABLE / DATABASE
        r"\bDELETE\s+FROM\b",                         # DELETE FROM (no WHERE)
        r"\bTRUNCATE\s+TABLE\b",                      # TRUNCATE TABLE
        r"\bchmod\s+777\b",                            # chmod 777
        r">\s*/dev/(sd[a-z]|zero)",                    # write to block devices (not /dev/null)
        r"\bmkfs\b",                                   # format filesystems
        r"\bdd\s+if=",                                 # dd raw disk writes
        r"\bkill\s+-9\b",                              # kill -9
        r"\bpkill\b",                                  # pkill
        r"\bnpm\s+publish\b",                          # npm publish
        r"\bgem\s+push\b",                             # gem push
        r"\bpip\s+install\b.*--break-system-packages", # system pip install
    ]
]


# ── Helpers ──────────────────────────────────────────────────────────────

def _latency_ms(start: float) -> int:
    return int(round((time.monotonic() - start) * 1000))


def _is_safe_mcp_tool(tool_name: str) -> bool:
    """Return True if *tool_name* matches a known-safe MCP service."""
    lower = tool_name.lower()
    return any(frag in lower for frag in _SAFE_MCP_FRAGMENTS)


def _bash_is_destructive(command: str) -> bool:
    """Return True if the Bash command matches a destructive pattern."""
    for pattern in DESTRUCTIVE_BASH_PATTERNS:
        if pattern.search(command):
            return True
    return False


# ── Haiku severity prompt ────────────────────────────────────────────────

def build_severity_prompt(
    tool_name: str,
    tool_input: dict,
    spec_text: str | None = None,
) -> str:
    parts = [
        "You classify the severity of an AI coding agent's tool use.",
        "",
    ]
    if spec_text:
        parts.extend([
            "Task context (what the agent is working on):",
            spec_text[:1000],
            "",
        ])
    parts.extend([
        f"Tool: {tool_name}",
        f"Input: {str(tool_input)[:500]}",
        "",
        "Assign a severity level 1-5:",
        "1 — Read-only project access (reading files, searching, listing directories)",
        "2 — Writing or editing files, safe shell commands (build, test, ls, cat, grep)",
        "3 — External API calls to known services (fetching from Jira, GitHub, Slack)",
        "4 — Ambiguous operations needing human judgment (multi-option selections, unknown tools, design decisions)",
        "5 — Destructive or dangerous (deleting files, force push, dropping databases, modifying production)",
        "",
        'Respond with JSON only: {"level": <1-5>, "reason": "brief explanation"}',
    ])
    return "\n".join(parts)


# ── Main classifier ─────────────────────────────────────────────────────

def classify_tool_severity(
    tool_name: str,
    tool_input: dict | None = None,
    spec_text: str | None = None,
    timeout: int = 15,
) -> dict:
    """Classify a tool use into severity levels 1-5.

    Returns ``{"level", "decision", "reason", "model", "latency_ms"}``.

    When the regex fast-path flags a tool at level 4+, Haiku gets a second
    look before escalating to the human.  If Haiku downgrades to level ≤ 3,
    the tool is auto-approved without human involvement.
    """
    tool_input = tool_input or {}
    start = time.monotonic()

    result = _fast_classify(tool_name, tool_input, spec_text, timeout, start)

    # If the fast-path flagged level ≥ 4 and it wasn't already a Haiku
    # result, ask Haiku for a second opinion before escalating to the human.
    if result["level"] >= 4 and result["model"] is None:
        haiku_result = _haiku_classify(tool_name, tool_input, spec_text, timeout, start)
        if haiku_result["level"] <= 3:
            return haiku_result

    return result


def _fast_classify(
    tool_name: str,
    tool_input: dict,
    spec_text: str | None,
    timeout: int,
    start: float,
) -> dict:
    """Deterministic regex/lookup classification.  No LLM calls."""

    # ── Known tool sets ─────────────────────────────────────────────
    if tool_name in LEVEL_1_TOOLS:
        return {
            "level": 1,
            "decision": "allow",
            "reason": f"Read-only tool: {tool_name}",
            "model": None,
            "latency_ms": _latency_ms(start),
        }

    if tool_name in LEVEL_2_TOOLS:
        return {
            "level": 2,
            "decision": "allow",
            "reason": f"File write/edit tool: {tool_name}",
            "model": None,
            "latency_ms": _latency_ms(start),
        }

    if tool_name in LEVEL_3_TOOLS:
        return {
            "level": 3,
            "decision": "allow",
            "reason": f"Known external API tool: {tool_name}",
            "model": None,
            "latency_ms": _latency_ms(start),
        }

    # ── Bash: check for destructive patterns ─────────────────────────
    if tool_name == "Bash":
        command = str(tool_input.get("command", ""))
        if _bash_is_destructive(command):
            return {
                "level": 5,
                "decision": "ask",
                "reason": f"Destructive Bash command detected",
                "model": None,
                "latency_ms": _latency_ms(start),
            }
        return {
            "level": 2,
            "decision": "allow",
            "reason": "Non-destructive Bash command",
            "model": None,
            "latency_ms": _latency_ms(start),
        }

    # ── MCP tools ────────────────────────────────────────────────────
    if tool_name.startswith("mcp__"):
        if _is_safe_mcp_tool(tool_name):
            return {
                "level": 3,
                "decision": "allow",
                "reason": f"Known-safe MCP tool: {tool_name}",
                "model": None,
                "latency_ms": _latency_ms(start),
            }
        # Unknown MCP → Haiku classification (model will be set)
        return _haiku_classify(tool_name, tool_input, spec_text, timeout, start)

    # ── Level 4 tools (always need judgment) ─────────────────────────
    if tool_name in LEVEL_4_TOOLS:
        return {
            "level": 4,
            "decision": "ask",
            "reason": f"Requires human judgment: {tool_name}",
            "model": None,
            "latency_ms": _latency_ms(start),
        }

    # ── Unknown tool → Haiku classification ──────────────────────────
    return _haiku_classify(tool_name, tool_input, spec_text, timeout, start)


def _haiku_classify(
    tool_name: str,
    tool_input: dict,
    spec_text: str | None,
    timeout: int,
    start: float,
) -> dict:
    """Call Haiku to classify an ambiguous tool use.  Defaults to level 5
    (escalate) on any failure."""
    prompt = build_severity_prompt(tool_name, tool_input, spec_text)
    try:
        result = run_haiku(prompt, timeout=timeout)
    except Exception as exc:
        return {
            "level": 5,
            "decision": "ask",
            "reason": f"Haiku error, defaulting to escalate: {exc}",
            "model": "haiku",
            "latency_ms": _latency_ms(start),
        }

    if isinstance(result, dict) and "error" not in result:
        level = result.get("level")
        reason = result.get("reason", "")
        if isinstance(level, int) and 1 <= level <= 5:
            return {
                "level": level,
                "decision": "allow" if level <= 3 else "ask",
                "reason": str(reason),
                "model": "haiku",
                "latency_ms": _latency_ms(start),
            }

    # Haiku returned unexpected format → default to escalate
    return {
        "level": 5,
        "decision": "ask",
        "reason": f"Unexpected Haiku response, defaulting to escalate",
        "model": "haiku",
        "latency_ms": _latency_ms(start),
    }


def should_auto_approve_level(level: int, threshold: int = 3) -> bool:
    """Return True if *level* is at or below the auto-approve *threshold*."""
    return level <= threshold
