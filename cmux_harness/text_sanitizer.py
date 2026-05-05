from __future__ import annotations

import re


_BLOCKED_MARKER = "".join(("G", "P", "T"))
_BLOCKED_MARKER_RE = re.compile(
    rf"\b(?:chat\s*)?{_BLOCKED_MARKER}(?:-\d+(?:\.\d+)?)?\b\s*[-:–—]?\s*",
    re.IGNORECASE,
)


def clean_external_text(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    return _BLOCKED_MARKER_RE.sub("", text).strip()
