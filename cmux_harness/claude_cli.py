from __future__ import annotations

import json
import shutil
import subprocess
from datetime import datetime, timezone


class ClaudeCliError(Exception):
    pass


def _extract_json(raw):
    if not raw:
        return None
    text = raw.strip()
    if text.startswith("```"):
        first_newline = text.find("\n")
        if first_newline != -1:
            text = text[first_newline + 1:]
        if text.endswith("```"):
            text = text[:-3]
    start = text.find("{")
    end = text.rfind("}") + 1
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(text[start:end])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _error_dict(message, error_type):
    return {
        "error": message,
        "type": error_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def run_claude_print(prompt: str, model: str | None = None, timeout: int = 60) -> str:
    claude_bin = shutil.which("claude") or "claude"
    cmd = [claude_bin, "--print"]
    if model:
        cmd.extend(["--model", model])
    cmd.extend(["-p", prompt])
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise ClaudeCliError(f"claude timed out after {timeout}s") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        message = stderr or stdout or f"claude exited with {exc.returncode}"
        raise ClaudeCliError(message) from exc
    except OSError as exc:
        raise ClaudeCliError(str(exc)) from exc
    return (result.stdout or "").strip()


def run_haiku(prompt: str, timeout: int = 30) -> dict | str:
    try:
        raw = run_claude_print(prompt, model="haiku", timeout=timeout)
    except ClaudeCliError as exc:
        return _error_dict(str(exc), "claude_cli_error")
    return _extract_json(raw) or raw


def run_sonnet(prompt: str, timeout: int = 60) -> dict | str:
    try:
        raw = run_claude_print(prompt, timeout=timeout)
    except ClaudeCliError as exc:
        return _error_dict(str(exc), "claude_cli_error")
    return _extract_json(raw) or raw
