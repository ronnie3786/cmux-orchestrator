from __future__ import annotations

import html
import json
import os
import re
import time
import urllib.error
import urllib.request
from datetime import date
from typing import Any

from .orchestrator_v2_security import load_local_env, redact_text


FIREWORKS_CHAT_COMPLETIONS_URL = "https://api.fireworks.ai/inference/v1/chat/completions"
MAX_TOOL_RESULTS = 8
MAX_TOOL_RESULT_CHARS = 2000
MIN_HTML_CHARS = 400

_FORBIDDEN_HTML_PATTERNS = [
    re.compile(r"<script", re.IGNORECASE),
    re.compile(r"javascript:", re.IGNORECASE),
    re.compile(r"srcdoc\s*=", re.IGNORECASE),
    re.compile(r"\bon[a-z]+\s*=", re.IGNORECASE),
]

_SYSTEM_PROMPT = """You generate one self-contained HTML document that renders a rich visual answer panel for a desktop voice assistant.

Rules:
- Return ONLY the HTML document, starting with <html> and ending with </html>. No markdown fences, no commentary.
- Exactly one <style> block in <head>. No <script> tags, no on* event handler attributes, no javascript: URLs, no srcdoc.
- No external resources: no remote images, fonts, stylesheets, or fetches. System font stack only.
- Design for a ~920px-wide dark desktop panel: background #0f1524, primary text #e6edf7, secondary text #8b96ad, surfaces #131a28, hairline borders rgba(148,163,196,0.14), 12px rounded corners.
- Lead with the hero fact: the single most important number or statement from the answer, large and immediately readable.
- Follow with 2-4 compact modules that organize the supporting detail. Use data tables for lists, status chips (small rounded tinted labels) for states, and key/value rows for facts when the tool results warrant them.
- Keep it dense and scannable. No filler prose, no lorem ipsum, no placeholder images."""


def enrich_payload(data: dict[str, Any]) -> dict[str, Any]:
    load_local_env()
    started = time.monotonic()
    question = str(data.get("question") or "").strip()
    answer = str(data.get("answer") or "").strip()
    if not answer:
        raise ValueError("answer required")
    title = str(data.get("title") or "").strip()
    tool_results = _truncated_tool_results(data.get("toolResults"))
    model = (
        os.environ.get("ORCHESTRATOR_V2_ENRICH_MODEL")
        or os.environ.get("ORCHESTRATOR_V2_AGENT_MODEL")
        or "accounts/fireworks/models/minimax-m2p7"
    )
    if os.environ.get("CMUX_ORCHESTRATOR_V2_FAKE_VOICE", "").strip().lower() in {"1", "true", "yes", "on"}:
        return {
            "ok": True,
            "html": _fixture_html(question, answer, title),
            "model": model,
            "elapsedS": round(time.monotonic() - started, 3),
        }
    fireworks_key = os.environ.get("FIREWORKS_API_KEY")
    if not fireworks_key:
        raise RuntimeError("FIREWORKS_API_KEY is not configured")
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": _user_prompt(question, answer, tool_results, title)},
        ],
        "max_tokens": 6000,
        "temperature": 0.5,
    }
    request = urllib.request.Request(
        FIREWORKS_CHAT_COMPLETIONS_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {fireworks_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            payload = json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Fireworks enrichment failed: HTTP {exc.code}") from exc
    except Exception as exc:
        raise RuntimeError(f"Fireworks enrichment failed: {redact_text(exc)}") from exc
    return {
        "ok": True,
        "html": _validate_html(_completion_text(payload)),
        "model": model,
        "elapsedS": round(time.monotonic() - started, 3),
    }


def _truncated_tool_results(raw: Any) -> list[dict[str, str]]:
    results: list[dict[str, str]] = []
    if not isinstance(raw, list):
        return results
    for item in raw[:MAX_TOOL_RESULTS]:
        if not isinstance(item, dict):
            continue
        results.append({
            "name": str(item.get("name") or "tool"),
            "preview": str(item.get("preview") or "")[:MAX_TOOL_RESULT_CHARS],
        })
    return results


def _user_prompt(question: str, answer: str, tool_results: list[dict[str, str]], title: str) -> str:
    lines = [
        f"Today's date: {date.today().isoformat()}",
        f"Panel title: {title or 'Orchestrator answer'}",
        f"Question: {question}",
        f"Answer: {answer}",
    ]
    if tool_results:
        lines.append("Tool results:")
        for item in tool_results:
            lines.append(f"- {item['name']}: {item['preview']}")
    else:
        lines.append("Tool results: none")
    lines.append("Build the dark desktop panel now.")
    return "\n".join(lines)


def _completion_text(payload: dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        return ""
    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    if not isinstance(message, dict):
        return ""
    return str(message.get("content") or "")


def _validate_html(raw: str) -> str:
    text = str(raw or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text).strip()
    lowered = text.lower()
    start = lowered.find("<html")
    end = lowered.rfind("</html>")
    if start < 0 or end < 0:
        raise RuntimeError("enrichment did not return an <html> document")
    text = text[start:end + len("</html>")]
    if len(text) < MIN_HTML_CHARS:
        raise RuntimeError("enrichment HTML is too short")
    for pattern in _FORBIDDEN_HTML_PATTERNS:
        if pattern.search(text):
            raise RuntimeError("enrichment HTML contains forbidden content")
    return text


def _fixture_html(question: str, answer: str, title: str) -> str:
    heading = html.escape(title or "Orchestrator answer")
    asked = html.escape(question or "(no question)")
    spoken = html.escape(answer or "(no answer)")
    return (
        '<html><head><meta charset="utf-8"><style>'
        "body{margin:0;padding:28px;background:#0f1524;color:#e6edf7;"
        "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:920px}"
        ".hero{font-size:34px;font-weight:700;margin-bottom:18px}"
        ".module{background:#131a28;border:1px solid rgba(148,163,196,0.14);"
        "border-radius:12px;padding:16px;margin-bottom:12px}"
        ".label{color:#8b96ad;font-size:12px;text-transform:uppercase;letter-spacing:0.08em;margin-bottom:6px}"
        "</style></head><body>"
        f'<div class="hero">{heading}</div>'
        f'<div class="module"><div class="label">Question</div><div>{asked}</div></div>'
        f'<div class="module"><div class="label">Answer</div><div>{spoken}</div></div>'
        '<div class="module"><div class="label">Source</div><div>Fixture enrichment panel</div></div>'
        "</body></html>"
    )
