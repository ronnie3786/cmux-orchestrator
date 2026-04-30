from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


class ClaudeCliError(Exception):
    pass


def _should_retry_without_model(message: str) -> bool:
    text = str(message or "").strip().lower()
    if not text:
        return False
    return (
        "invalid api key" in text
        or "fix external api key" in text
        or "external api key" in text
    )


def _is_login_error(message: str) -> bool:
    text = str(message or "").strip().lower()
    if not text:
        return False
    return (
        "not logged in" in text
        or "please run /login" in text
        or "run /login" in text
    )


def _should_try_next_binary(message: str) -> bool:
    text = str(message or "").strip().lower()
    if not text:
        return False
    return (
        _is_login_error(text)
        or "needs an update" in text
        or "newer version" in text
        or "claude update" in text
    )


def _is_cmux_app_claude(path: str) -> bool:
    normalized = os.path.realpath(os.path.expanduser(str(path or "")))
    return normalized.endswith("/cmux.app/Contents/Resources/bin/claude")


def _add_executable_candidate(candidates: list[str], path: str | None) -> None:
    if not path:
        return
    expanded = os.path.expanduser(str(path).strip())
    if not expanded:
        return
    if os.path.isabs(expanded):
        if not os.access(expanded, os.X_OK):
            return
        candidates.append(expanded)
        return
    resolved = shutil.which(expanded)
    if resolved:
        candidates.append(resolved)


def claude_binary_candidates() -> list[str]:
    """Return Claude CLI candidates, preferring user-installed binaries.

    The macOS app bundle places its own ``claude`` first on PATH, but that
    copy may not share the user's terminal login. Prefer the user's CLI and
    keep the bundled copy as a fallback.
    """
    env_candidates: list[str] = []
    all_candidates: list[str] = []

    _add_executable_candidate(
        env_candidates,
        os.environ.get("CMUX_CLAUDE_BIN") or os.environ.get("CLAUDE_BIN"),
    )

    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        _add_executable_candidate(all_candidates, os.path.join(directory, "claude"))
    _add_executable_candidate(all_candidates, shutil.which("claude"))

    home = Path.home()
    for known_path in (
        home / ".local" / "bin" / "claude",
        Path("/opt/homebrew/bin/claude"),
        Path("/usr/local/bin/claude"),
    ):
        _add_executable_candidate(all_candidates, str(known_path))

    ordered = env_candidates[:]
    user_candidates = [path for path in all_candidates if not _is_cmux_app_claude(path)]
    bundled_candidates = [path for path in all_candidates if _is_cmux_app_claude(path)]
    ordered.extend(user_candidates)
    ordered.extend(bundled_candidates)

    deduped: list[str] = []
    seen: set[str] = set()
    for path in ordered:
        key = os.path.realpath(path)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(path)
    return deduped


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
    candidates = claude_binary_candidates() or ["claude"]
    last_retryable_error: ClaudeCliError | None = None
    for claude_bin in candidates:
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
            if _should_try_next_binary(message):
                last_retryable_error = ClaudeCliError(message)
                continue
            raise ClaudeCliError(message) from exc
        except OSError as exc:
            raise ClaudeCliError(str(exc)) from exc

        output = (result.stdout or "").strip()
        if _should_try_next_binary(output):
            last_retryable_error = ClaudeCliError(output)
            continue
        return output

    if last_retryable_error is not None:
        raise last_retryable_error
    raise ClaudeCliError("claude binary not found")


def run_haiku(prompt: str, timeout: int = 30) -> dict | str:
    try:
        raw = run_claude_print(prompt, model="haiku", timeout=timeout)
    except ClaudeCliError as exc:
        if not _should_retry_without_model(str(exc)):
            return _error_dict(str(exc), "claude_cli_error")
        try:
            raw = run_claude_print(prompt, timeout=timeout)
        except ClaudeCliError as retry_exc:
            return _error_dict(str(retry_exc), "claude_cli_error")
    return _extract_json(raw) or raw


def run_sonnet(prompt: str, timeout: int = 60) -> dict | str:
    try:
        raw = run_claude_print(prompt, timeout=timeout)
    except ClaudeCliError as exc:
        return _error_dict(str(exc), "claude_cli_error")
    return _extract_json(raw) or raw
