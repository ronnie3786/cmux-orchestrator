from __future__ import annotations

import os
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Any, Callable, Mapping

from .text_sanitizer import clean_external_text


_FEED_PLUGIN_MARKER = "cmux-feed-plugin-marker"
_FEED_PLUGIN_RELATIVE_PATH = Path(".config/opencode/plugins/cmux-feed.js")
_APPLICATION_CMUX_PATH = Path("/Applications/cmux.app/Contents/MacOS/cmux")
_INSTALL_ARGUMENTS = ["hooks", "opencode", "install", "--yes"]
_INSTALL_TIMEOUT_SECONDS = 20
_MAX_DIAGNOSTIC_CHARS = 800
_INSTALL_LOCK = threading.Lock()


def integration_status() -> dict[str, Any]:
    """Return the local OpenCode feed-hook readiness without changing anything."""
    plugin_path = _opencode_plugin_path()
    cmux_path, cmux_source = _find_cmux_executable()
    plugin_exists = plugin_path.is_file()
    installed = _plugin_has_marker(plugin_path)

    if installed:
        state = "ready"
        summary = "OpenCode native permission and question controls are enabled."
    elif cmux_path:
        state = "needs_install"
        summary = "OpenCode native controls are available but have not been enabled yet."
    else:
        state = "cmux_unavailable"
        summary = "A usable cmux executable is required to enable OpenCode native controls."

    return {
        "ok": True,
        "status": state,
        "installed": installed,
        "pluginExists": plugin_exists,
        "pluginPath": str(plugin_path),
        "cmuxAvailable": bool(cmux_path),
        "cmuxPath": cmux_path or "",
        "cmuxSource": cmux_source,
        "needsInstall": not installed,
        "needsRestart": False,
        "summary": summary,
    }


def install_integration() -> dict[str, Any]:
    """Install the OpenCode feed hook after an explicit caller request."""
    with _INSTALL_LOCK:
        before = integration_status()
        if before["installed"]:
            return {
                **before,
                "changed": False,
                "summary": "OpenCode native controls are already enabled.",
            }

        cmux_path = str(before.get("cmuxPath") or "")
        if not cmux_path:
            return _install_failure(
                before,
                error_code="cmux_unavailable",
                error="A usable cmux executable was not found.",
            )

        command = [cmux_path, *_INSTALL_ARGUMENTS]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=_INSTALL_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            return _install_failure(
                before,
                error_code="install_timeout",
                error="Installing the OpenCode integration timed out.",
                diagnostic=_clean_diagnostic(exc.stdout, exc.stderr),
            )
        except OSError as exc:
            return _install_failure(
                before,
                error_code="install_launch_failed",
                error=f"Could not launch cmux: {exc}",
            )

        diagnostic = _clean_diagnostic(result.stdout, result.stderr)
        if result.returncode != 0:
            return _install_failure(
                before,
                error_code="install_failed",
                error="cmux could not enable the OpenCode integration.",
                diagnostic=diagnostic,
            )

        after = integration_status()
        if not after["installed"]:
            return _install_failure(
                after,
                error_code="plugin_not_detected",
                error="cmux completed successfully, but the OpenCode feed plugin was not detected.",
                diagnostic=diagnostic,
            )

        return {
            **after,
            "changed": True,
            "needsRestart": True,
            "summary": "OpenCode native controls are enabled. Restart active OpenCode sessions to use them.",
        }


def _opencode_plugin_path() -> Path:
    return Path.home() / _FEED_PLUGIN_RELATIVE_PATH


def _find_cmux_executable(
    *,
    environ: Mapping[str, str] | None = None,
    application_path: Path = _APPLICATION_CMUX_PATH,
    which: Callable[[str], str | None] = shutil.which,
) -> tuple[str, str]:
    environment = os.environ if environ is None else environ
    candidates: list[tuple[str, str]] = []

    configured_path = str(environment.get("CMUX_CLI_PATH") or "").strip()
    if configured_path:
        candidates.append((configured_path, "environment"))
    candidates.append((str(application_path), "application"))

    path_candidate = which("cmux")
    if path_candidate:
        candidates.append((path_candidate, "path"))

    seen: set[str] = set()
    for value, source in candidates:
        candidate = Path(value).expanduser()
        normalized = str(candidate)
        if normalized in seen:
            continue
        seen.add(normalized)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return normalized, source
    return "", ""


def _plugin_has_marker(plugin_path: Path) -> bool:
    try:
        return _FEED_PLUGIN_MARKER in plugin_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def _install_failure(
    status: dict[str, Any],
    *,
    error_code: str,
    error: str,
    diagnostic: str = "",
) -> dict[str, Any]:
    return {
        **status,
        "ok": False,
        "changed": False,
        "errorCode": error_code,
        "error": error,
        "diagnostic": diagnostic,
    }


def _clean_diagnostic(*parts: object) -> str:
    output = "\n".join(str(part or "").strip() for part in parts if str(part or "").strip())
    output = clean_external_text(output)
    if len(output) > _MAX_DIAGNOSTIC_CHARS:
        return output[:_MAX_DIAGNOSTIC_CHARS].rstrip() + "..."
    return output
