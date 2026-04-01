import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from .storage import debug_log, read_review_file, write_review_file

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3.5:35b-a3b-nvfp4")


def parse_review_json(raw):
    if not raw:
        return None
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\s*```$", "", text)
    start = text.find("{")
    end = text.rfind("}") + 1
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(text[start:end])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def build_review_prompt(review_data):
    approval_log = review_data.get("approvalLog") or []
    approved_count = 0
    flagged_count = 0
    for entry in approval_log:
        action = str(entry.get("action", "")).lower()
        if "needs human" in action or "flagged" in action:
            flagged_count += 1
        else:
            approved_count += 1

    git_diff = (review_data.get("gitDiff") or "").strip()
    git_diff_stat = (review_data.get("gitDiffStat") or "").strip()
    git_log = (review_data.get("gitLog") or "").strip()
    has_code_changes = bool(git_diff or git_diff_stat)

    prompt = (
        "You are reviewing a completed AI coding agent (Claude Code) session.\n"
        "Your job is to summarize what happened and tell the developer what to do next.\n"
        "EVERY session gets a review, whether or not code was changed.\n\n"
        f"Workspace: {review_data.get('workspaceName', '')}\n"
        f"Branch: {review_data.get('branch', '')}\n"
        f"Working directory: {review_data.get('cwd', '')}\n"
        f"Session duration: {review_data.get('duration', 0)} seconds\n"
        f"Session cost: {review_data.get('finalCost', '')}\n"
        f"Actions auto-approved: {approved_count}\n"
        f"Actions flagged for human: {flagged_count}\n\n"
        "── Claude Code's final output (last 50 lines) ──\n"
        f"{review_data.get('terminalSnapshot', '')}\n\n"
    )

    if has_code_changes:
        prompt += (
            "── Git diff summary ──\n"
            f"{git_diff_stat}\n\n"
            "── Recent commits ──\n"
            f"{git_log}\n\n"
            "── Full diff ──\n"
            f"{git_diff}\n\n"
        )
    else:
        prompt += (
            "── Note: No uncommitted code changes detected ──\n"
            "This session may have involved exploration, debugging, planning,\n"
            "reading code, answering questions, or changes that were already committed.\n"
            "Review the terminal output above to determine what happened.\n\n"
        )
        if git_log:
            prompt += (
                "── Recent commits (may include this session's work) ──\n"
                f"{git_log}\n\n"
            )

    prompt += (
        "Respond with ONLY a JSON object:\n"
        "{\n"
        '  "summary": "One-line description of what happened in this session",\n'
        '  "whatHappened": "2-4 sentence description of what Claude did, what was accomplished, and any important context",\n'
        '  "filesChanged": ["list", "of", "files"] or [] if no changes,\n'
        '  "linesAdded": number or 0,\n'
        '  "linesRemoved": number or 0,\n'
        '  "confidence": "high" | "medium" | "low",\n'
        '  "issues": ["list of concerns, empty if none"],\n'
        '  "readyForPR": true | false (false if no code changes),\n'
        '  "nextSteps": "What should the developer do next based on this session",\n'
        '  "recommendation": "Brief recommendation for the developer",\n'
        '  "highlights": ["Notable good decisions or patterns worth calling out"]\n'
        "}\n"
    )
    debug_log({
        "event": "review_prompt_built",
        "workspace": review_data.get("workspaceIndex"),
        "approved_count": approved_count,
        "flagged_count": flagged_count,
        "prompt_chars": len(prompt),
    })
    return prompt


def run_review_ollama(prompt, model=None):
    """Run review via Ollama. Returns (parsed_dict_or_None, error_string, model_used)."""
    model = model or OLLAMA_MODEL
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "think": False,
        "options": {"num_predict": 1200, "temperature": 0.1},
    }
    debug_log({"event": "review_ollama_start", "model": model})
    try:
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
        raw = result.get("response", "")
        parsed = parse_review_json(raw)
        if parsed is None:
            err = "invalid JSON response from Ollama"
            debug_log({"event": "review_ollama_parse_error", "model": model, "raw": raw[:2000]})
            return None, err, model
        debug_log({"event": "review_ollama_success", "model": model, "keys": sorted(parsed.keys())})
        return parsed, "", model
    except urllib.error.HTTPError as e:
        msg = (
            f"Ollama returned {e.code}: model '{model}' not found — run 'ollama pull {model}'"
            if e.code == 404
            else str(e)
        )
        debug_log({"event": "review_ollama_error", "model": model, "error": msg})
        return None, msg, model
    except Exception as e:
        msg = str(e)
        debug_log({"event": "review_ollama_error", "model": model, "error": msg})
        return None, msg, model


def run_review_lmstudio(prompt, model=None, endpoint="http://100.89.93.84:1234"):
    """Run review via LM Studio. Returns (parsed_dict_or_None, error_string, model_used)."""
    model = model or OLLAMA_MODEL
    completions_url = f"{endpoint}/v1/chat/completions"
    try:
        with urllib.request.urlopen(f"{endpoint}/v1/models", timeout=5) as resp:
            models_data = json.loads(resp.read())
        loaded = models_data.get("data") or []
        if loaded and isinstance(loaded[0], dict):
            model = loaded[0].get("id", model) or model
    except Exception as e:
        debug_log({"event": "review_lmstudio_models_error", "error": str(e), "fallback_model": model})

    payload = {
        "model": model,
        "messages": [
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.1,
        "stream": False,
    }
    debug_log({"event": "review_lmstudio_start", "model": model})
    try:
        req = urllib.request.Request(
            completions_url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
        choices = result.get("choices") or []
        message = choices[0].get("message", {}) if choices else {}
        raw = message.get("content", "")
        parsed = parse_review_json(raw)
        if parsed is None:
            err = "invalid JSON response from LM Studio"
            debug_log({"event": "review_lmstudio_parse_error", "model": model, "raw": raw[:2000]})
            return None, err, model
        debug_log({"event": "review_lmstudio_success", "model": model, "keys": sorted(parsed.keys())})
        return parsed, "", model
    except Exception as e:
        msg = str(e)
        debug_log({"event": "review_lmstudio_error", "model": model, "error": msg})
        return None, msg, model


def run_review_claude(prompt, model_override=None):
    """Run review via Claude CLI. Returns (parsed_dict_or_None, error_string, model_used).
    Falls back to run_review_ollama if the claude binary is not found.
    """
    claude_bin = shutil.which("claude")
    if not claude_bin:
        debug_log({"event": "review_claude_missing", "fallback": "ollama"})
        return run_review_ollama(prompt, model=model_override)

    model_used = model_override or "claude"
    debug_log({"event": "review_claude_start", "binary": claude_bin})
    try:
        result = subprocess.run(
            [claude_bin, "--print", "-p", prompt],
            capture_output=True,
            text=True,
            timeout=120,
        )
        raw = (result.stdout or "").strip()
        if result.returncode != 0 and not raw:
            err = (result.stderr or "").strip() or f"claude exited with {result.returncode}"
            debug_log({"event": "review_claude_error", "error": err})
            return None, err, model_used
        parsed = parse_review_json(raw)
        if parsed is None:
            err = "invalid JSON response from Claude"
            debug_log({"event": "review_claude_parse_error", "raw": raw[:2000], "stderr": (result.stderr or "")[:1000]})
            return None, err, model_used
        debug_log({"event": "review_claude_success", "keys": sorted(parsed.keys())})
        return parsed, "", model_used
    except Exception as e:
        msg = str(e)
        debug_log({"event": "review_claude_exception", "error": msg})
        return None, msg, model_used


def run_review(review_path, review_model, review_backend, model_override=None, backend_override=None):
    """Orchestrate a full review cycle for the given review file path.

    Reads the review file, calls the appropriate backend, and writes results back.
    """
    start_ts = time.time()
    path = Path(review_path)
    review_data = read_review_file(path)
    if review_data is None:
        debug_log({"event": "review_load_error", "path": str(path)})
        return

    review_data["reviewStatus"] = "reviewing"
    review_data.pop("reviewError", None)
    try:
        write_review_file(path, review_data)
    except OSError as e:
        debug_log({"event": "review_write_error", "path": str(path), "stage": "reviewing", "error": str(e)})
        return

    prompt = build_review_prompt(review_data)
    backend = backend_override or review_backend
    configured_model = model_override or review_model
    debug_log({"event": "review_start", "path": str(path), "backend": backend, "model": configured_model})

    if backend == "lmstudio":
        review_result, error_message, resolved_model = run_review_lmstudio(prompt, model=configured_model)
    elif backend == "ollama":
        review_result, error_message, resolved_model = run_review_ollama(prompt, model=configured_model)
    else:
        review_result, error_message, resolved_model = run_review_claude(prompt, model_override=configured_model)

    resolved_model = resolved_model or configured_model or OLLAMA_MODEL
    review_data = read_review_file(path) or review_data
    duration = round(time.time() - start_ts, 1)

    if review_result is None:
        review_data["reviewStatus"] = "error"
        review_data["reviewError"] = error_message or "review backend failed"
        review_data["reviewDuration"] = duration
        review_data["reviewModel"] = resolved_model
        review_data["reviewedAt"] = datetime.now(timezone.utc).isoformat()
        try:
            write_review_file(path, review_data)
        except OSError as e:
            debug_log({"event": "review_write_error", "path": str(path), "stage": "error", "error": str(e)})
        debug_log({"event": "review_failed", "path": str(path), "backend": backend, "error": review_data["reviewError"]})
        return

    confidence = str(review_result.get("confidence", "")).lower()
    issues = review_result.get("issues") or []
    review_data["review"] = review_result
    review_data["reviewStatus"] = "flagged" if confidence == "low" or bool(issues) else "reviewed"
    review_data["reviewedAt"] = datetime.now(timezone.utc).isoformat()
    review_data["reviewModel"] = resolved_model
    review_data["reviewDuration"] = duration
    review_data.pop("reviewError", None)
    try:
        write_review_file(path, review_data)
    except OSError as e:
        debug_log({"event": "review_write_error", "path": str(path), "stage": "success", "error": str(e)})
        return
    debug_log({
        "event": "review_completed",
        "path": str(path),
        "backend": backend,
        "status": review_data["reviewStatus"],
        "duration": duration,
    })
