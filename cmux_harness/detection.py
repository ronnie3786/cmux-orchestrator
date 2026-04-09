"""Terminal detection utilities for Claude Code sessions.

Session detection (``detect_claude_session``) and screen fingerprinting
(``fingerprint``) are still used by the engine for dashboard display.

Prompt detection and approval classification have been replaced by
PreToolUse hooks — see :mod:`cmux_harness.severity` and
:mod:`cmux_harness.routes.hooks`.
"""

import hashlib
import re


def detect_claude_session(screen_text):
    """Return True if Claude Code appears to be running in this terminal.
    Looks for Claude Code REPL indicators, active thinking/musing, tool use,
    or the characteristic prompt/status lines."""
    if not screen_text:
        return False
    # Check last 30 lines for Claude Code signatures
    lines = screen_text.strip().splitlines()
    tail = "\n".join(lines[-30:]) if len(lines) > 30 else screen_text

    # Early exit: if the last non-empty line is a plain shell prompt and the
    # last 5 lines have no Claude REPL indicators (Model:/Cost:/Ctx:), the
    # session has ended (e.g. after /exit). This prevents scrollback text from
    # a prior Claude Code session from triggering a false positive.
    recent = "\n".join(lines[-5:]) if len(lines) >= 5 else "\n".join(lines)
    last_line = next((l for l in reversed(lines) if l.strip()), "")
    if (re.search(r"\w+@\w+[^\n]*[%$#]\s*$", last_line)
            and not re.search(r"(Model:\s*(Sonnet|Opus|Haiku|Claude)|Cost:\s*\$|Ctx:\s*\d)", recent)):
        return False
    # Claude Code REPL: "❯" with Model:/Cost:/Ctx: lines nearby
    if re.search(r"(Model:\s*(Sonnet|Opus|Haiku|Claude|claude)|Cost:\s*\$|Ctx:\s*\d)", tail):
        return True
    # Active Claude Code: thinking, musing, tool use
    if re.search(r"(Musing\.\.\.|Thinking\.\.\.|⚡\s*(Read|Edit|Write|Bash|MultiEdit|Search|Glob|Grep|ListDir|Fetch|Browse|TodoRead|TodoWrite|WebFetch|MCP))", tail):
        return True
    # Claude Code permission prompts
    if re.search(r"(Allow\s+(Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit)|Do you want to proceed|\(Y/n\)|\(y/n\))", tail):
        return True
    # Claude Code compact prompt with ❯ (not a regular shell prompt)
    # The ❯ followed by claude-specific content
    if re.search(r"[❯)]\s*(Yes|No|Allow|Deny|Approve|Confirm)", tail):
        return True
    # Claude Code TUI header (box-drawing chars around "Claude Code")
    # Must appear in a TUI context — not in a log line (which starts with a timestamp or "[harness]")
    for line in tail.splitlines():
        stripped = line.strip()
        if "Claude Code" in stripped:
            if re.match(r"^\[20\d\d-|\[harness\]|approved ws=|ws=", stripped):
                continue
            return True
    # Claude Code welcome screen after /clear (model names without "Model:" prefix)
    if re.search(r"(Welcome back|Claude (Enterprise|Pro|Max|Team|Free))", tail):
        return True
    # Claude Code model identifier in welcome screen (not prefixed by "Model:")
    if re.search(r"(Opus|Sonnet|Haiku)\s+[\d.]+\s*\(", tail):
        return True
    # Claude Code Ink TUI menu (numbered options with navigation hints)
    if re.search(r"Enter to select.*Esc to cancel", tail):
        return True
    # "claude" command was recently run (visible in scrollback)
    if re.search(r"^\$?\s*claude\s*$", tail, re.MULTILINE):
        return True
    return False


_PERMISSION_PROMPT_RE = re.compile(
    r"(Do you want to proceed"
    r"|Permission rule .+ requires confirmation"
    r"|Allow\s+(Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit)"
    r"|\([Yy](?:/[Nn]|es/no)\)"
    r"|[❯)]\s*1\.\s*Yes)",
    re.IGNORECASE,
)


def is_permission_prompt(screen_text: str) -> bool:
    """Return True if the screen shows a Claude Code permission prompt.

    Lightweight regex check — no LLM involved.  Used by the fallback
    approval system to confirm a stuck screen is actually a permission
    prompt before sending Enter.
    """
    if not screen_text:
        return False
    tail = "\n".join(screen_text.splitlines()[-25:])
    return bool(_PERMISSION_PROMPT_RE.search(tail))


def fingerprint(screen_text):
    """Hash of last 5 lines — used to avoid double-processing."""
    lines = screen_text.strip().splitlines()
    chunk = "\n".join(lines[-5:]) if len(lines) >= 5 else screen_text
    return hashlib.md5(chunk.encode()).hexdigest()
