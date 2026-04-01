import hashlib
import json
import os
import re

from .storage import debug_log

# ---------------------------------------------------------------------------
# LLM classification (Ollama local model)
# ---------------------------------------------------------------------------

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:35b-a3b-nvfp4")
USE_LLM = os.environ.get("USE_LLM", "1") != "0"  # enabled by default

_LLM_SYSTEM = """You classify terminal prompts from Claude Code (an AI coding assistant).
When the terminal shows a PERMISSION prompt or confirmation dialog, decide the correct response.
Reply with ONLY a JSON object, no markdown, no explanation.

Rules:
- Permission/confirmation prompts with Yes/No options → auto-approve (action: "enter")
- Y/n or Yes/no inline prompts → auto-approve (action: "y")
- "Allow <tool>" prompts → auto-approve (action: "y")
- Menus where ALL options are permission variants (Yes, No, "Yes and don't ask again", "Yes, allow X from Y") → auto-approve by pressing Enter if cursor is on a Yes/Allow option
- Domain-specific choices requiring human judgment (which file to edit, which approach to take, pick a specific item) → needs human (action: "skip")
- Claude Code idle REPL showing "❯" with "Model:" and "Cost:" lines nearby → NOT waiting
- A shell prompt (like "user@host %") → NOT waiting
- Claude Code showing "Musing…" or "Thinking…" → NOT waiting, it's working
- Claude Code actively running a tool (showing "⚡ Read", "⚡ Bash", etc.) → NOT waiting
- If the terminal is NOT waiting for a permission prompt → not waiting

IMPORTANT: Options like "Yes, allow reading from X", "Yes, and don't ask again for: bash ...", "Yes, allow X from this project" are ALL permission grants, NOT domain-specific choices. They should be auto-approved.

JSON format: {"waiting": bool, "action": "enter"|"y"|"skip", "safe": bool, "reason": "brief"}
- action "enter" = press Enter key (for menus where cursor ›/❯ is on the right option)
- action "y" = type the letter y (for Y/n prompts)
- action "skip" = needs human decision, don't send anything
- waiting = true ONLY for permission/approval prompts, NOT for idle REPLs or shell prompts"""


def llm_classify(screen_text, model=None, ollama_available_checker=None):
    """Ask a local Ollama model to classify the terminal screen.
    Returns (pattern_name, action) or None on failure.

    model: override the Ollama model name (defaults to OLLAMA_MODEL)
    ollama_available_checker: callable returning bool; if provided and returns
        False, skip the LLM call entirely.
    """
    if not USE_LLM:
        return None
    if ollama_available_checker is not None and not ollama_available_checker():
        return None
    # Only send the last 25 lines to keep token count low
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else screen_text

    active_model = model if model is not None else OLLAMA_MODEL
    payload = {
        "model": active_model,
        "system": _LLM_SYSTEM,
        "prompt": f"Terminal screen:\n\n{tail}\n\nClassify this terminal screen.",
        "stream": False,
        "think": False,
        "options": {"num_predict": 80, "temperature": 0.1},
    }
    try:
        import urllib.request
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
        raw = result.get("response", "").strip()
        # Extract JSON from response (model might add whitespace)
        # Find first { and last }
        start = raw.find("{")
        end = raw.rfind("}") + 1
        if start < 0 or end <= start:
            return None
        parsed = json.loads(raw[start:end])
        debug_log({
            "event": "llm_response",
            "raw": raw,
            "parsed": parsed,
            "model": active_model,
        })
        if not parsed.get("waiting", False):
            return None
        action = parsed.get("action", "skip")
        safe = parsed.get("safe", False)
        reason = parsed.get("reason", "")
        if action == "skip" or not safe:
            return ("needs_human", "skip")
        # Fix action mismatch: if the screen is a numbered menu (Enter to select),
        # always use "enter" even if the LLM said "y". Typing "y" in a menu does nothing.
        if action == "y" and re.search(r"Enter to select|Esc to cancel", tail):
            action = "enter"
        return (f"llm:{reason[:40]}", action)
    except Exception as e:
        print(f"[harness] LLM error: {e}")
        debug_log({"event": "llm_error", "error": str(e)})
        return None


def detect_claude_session(screen_text):
    """Return True if Claude Code appears to be running in this terminal.
    Looks for Claude Code REPL indicators, active thinking/musing, tool use,
    or the characteristic prompt/status lines."""
    if not screen_text:
        return False
    # Check last 30 lines for Claude Code signatures
    lines = screen_text.strip().splitlines()
    tail = "\n".join(lines[-30:]) if len(lines) > 30 else screen_text
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
    if re.search(r"Claude Code", tail):
        return True
    # Claude Code welcome screen after /clear (model names without "Model:" prefix)
    if re.search(r"(Welcome back|Claude (Enterprise|Pro|Max|Team|Free))", tail):
        return True
    # Claude Code model identifier in welcome screen (not prefixed by "Model:")
    if re.search(r"(Opus|Sonnet|Haiku)\s+[\d.]+\s*\(", tail):
        return True
    # "claude" command was recently run (visible in scrollback)
    if re.search(r"^\$?\s*claude\s*$", tail, re.MULTILINE):
        return True
    return False


# ---------------------------------------------------------------------------
# Prompt detection (regex fast-path + LLM fallback)
# ---------------------------------------------------------------------------

PROMPT_PATTERNS = [
    # (name, primary_regex, secondary_regex_or_None, action: "enter" | "y")
    # confirm_menu and yes_menu are handled in the menu detection block
    # inside detect_prompt() before these patterns are checked.
    ("yn_prompt",     r"\([Yy](?:/[Nn]|es/no)\)", None, "y"),
    ("tool_approval", r"Allow (Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit|ListDir|Glob|Grep|TodoRead|TodoWrite|WebFetch|WebSearch|Search|Task|NotebookRead|NotebookEdit)", None, "y"),
    ("button_yes",    r"[❯)\>]\s*(Yes|Allow)", None, "enter"),
    # allow_generic removed — too broad, caused false matches on menu content above the cursor
    ("run_command",   r"(Run|Execute) (this|the) (command|script)?", None, "y"),
    ("apply_changes", r"(Apply|Write|Save) (these |the )?(changes|edits|file)?", None, "y"),
    ("trust_prompt",  r"Do you (trust|want to allow)", None, "y"),
]

# Claude Code's Ink UI renders ❯ as the menu cursor, but cmux read_screen
# often captures it as ) instead. Match both characters as cursor indicators.
_CURSOR_CHARS = r"[❯›)\>]"
_NUMBERED_MENU_RE = re.compile(r"^\s*\d+[.)]\s+")
_AFFIRM_RE = re.compile(r"(Yes|Allow|Confirm|Approve|Accept|Proceed|Continue)", re.I)

# Regex to detect Claude Code's idle REPL (not a permission prompt)
_REPL_IDLE_RE = re.compile(r"(Model:\s*(Sonnet|Opus|Haiku|Claude)|Cost:\s*\$|Ctx:\s*\d)")


def is_permission_menu(options_text):
    """Check if menu options are all Yes/No variants (permission prompt)
    vs domain-specific choices (needs human).
    Returns True if it's a standard permission prompt."""
    # Extract option text (everything after "N. " or "N) " — also handles "N.Text" with no space)
    option_texts = re.findall(r"\d+[.)]\s*(.+)", options_text)
    has_affirmative = False
    has_domain_specific = False
    for opt in option_texts:
        opt_lower = opt.strip().lower()
        # Skip "Type something" and "Chat about this" — always present in Claude Code menus
        if opt_lower.startswith("type something") or opt_lower.startswith("chat about"):
            continue
        # Standard permission/confirmation options
        if any(opt_lower.startswith(w) for w in ["yes", "no", "allow", "deny", "skip",
                "confirm", "approve", "accept", "proceed", "continue", "cancel",
                "modify", "re-search", "add more", "change", "replace"]):
            if any(opt_lower.startswith(w) for w in ["yes", "allow", "confirm", "approve",
                    "accept", "proceed", "continue"]):
                has_affirmative = True
            continue
        # If we find anything else, it's domain-specific
        has_domain_specific = True
    # It's a permission menu if there's an affirmative option and no domain-specific ones
    return has_affirmative and not has_domain_specific


def detect_prompt(screen_text, model=None, ollama_available_checker=None):
    """Return (pattern_name, action) or None if no prompt detected.
    Returns ("needs_human", "skip") if a prompt needs manual intervention.

    Strategy: LLM-primary. The local model classifies every screen.
    Only two fast pre-checks:
    1. Idle REPL detection (skip without burning LLM tokens)
    2. Plain shell prompt detection (skip without burning LLM tokens)

    model: override the Ollama model name passed to llm_classify
    ollama_available_checker: callable returning bool passed to llm_classify
    """
    if not screen_text:
        return None
    # Strip trailing blank lines — read_screen returns fixed-height output
    # with blank padding below the actual terminal content
    lines = screen_text.splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None
    tail = "\n".join(lines[-25:]) if len(lines) > 25 else "\n".join(lines)

    # SKIP: Claude Code idle REPL (has ❯ but also Model:/Cost: lines)
    if _REPL_IDLE_RE.search(tail):
        return None

    # SKIP: Plain shell prompt with no Claude Code indicators
    last_chunk = "\n".join(lines[-10:]) if len(lines) > 10 else "\n".join(lines)
    if not re.search(r"(Allow |Do you want|proceed|\([Yy](?:/[Nn]|es/no)\)|Enter to select|Esc to cancel|Musing|Thinking|⚡|Model:|Cost:|Ctx:)", last_chunk):
        # No prompt indicators at all — likely just a shell
        return None

    # LLM classifies everything else
    llm_result = llm_classify(screen_text, model=model, ollama_available_checker=ollama_available_checker)
    if llm_result is not None:
        return llm_result

    return None


def fingerprint(screen_text):
    """Hash of last 5 lines — used to avoid double-approving."""
    lines = screen_text.strip().splitlines()
    chunk = "\n".join(lines[-5:]) if len(lines) >= 5 else screen_text
    return hashlib.md5(chunk.encode()).hexdigest()
