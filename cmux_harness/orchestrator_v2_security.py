from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any


REDACTED = "[REDACTED]"

_SENSITIVE_KEY_RE = re.compile(
    r"(api[_-]?key|authorization|bearer|token|secret|client_secret|password|credential)",
    re.IGNORECASE,
)
_SECRET_VALUE_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"ek_[A-Za-z0-9_\-]{16,}"),
    re.compile(r"fw_[A-Za-z0-9_\-]{16,}"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._\-]{12,}"),
    re.compile(r"(?i)(FIREWORKS_API_KEY|OPENAI_API_KEY|ELEVENLABS_API_KEY)\s*=\s*[^\s]+"),
]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_local_env(root: Path | None = None) -> dict[str, str]:
    """Load .env.local into process env without returning secret values to callers."""
    root = root or repo_root()
    env_path = root / ".env.local"
    loaded: dict[str, str] = {}
    try:
        lines = env_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return loaded
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if not key:
            continue
        os.environ.setdefault(key, value)
        loaded[key] = value
    return loaded


def redact_text(value: Any) -> str:
    text = str(value or "")
    for pattern in _SECRET_VALUE_PATTERNS:
        text = pattern.sub(REDACTED, text)
    return text


def redact_value(value: Any) -> Any:
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            redacted[key_text] = REDACTED if _SENSITIVE_KEY_RE.search(key_text) else redact_value(item)
        return redacted
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, tuple):
        return [redact_value(item) for item in value]
    if isinstance(value, str):
        return redact_text(value)
    return value


def is_configured(env_name: str) -> bool:
    return bool(str(os.environ.get(env_name) or "").strip())
