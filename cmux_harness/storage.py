"""storage.py — Logging, config, and review file I/O for cmux-harness.

Only imports from Python stdlib: json, re, datetime/timezone, pathlib.Path
"""

import json
import re
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Persistent log directory
# ---------------------------------------------------------------------------

LOG_DIR = Path.home() / ".cmux-harness"
LOG_DIR.mkdir(parents=True, exist_ok=True)
REVIEWS_DIR = LOG_DIR / "reviews"
REVIEWS_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "approval-log.jsonl"
DEBUG_LOG = LOG_DIR / "debug-log.jsonl"
CONFIG_FILE = LOG_DIR / "workspace-config.json"

MAX_DEBUG_LOG_SIZE = 10 * 1024 * 1024  # 10MB


def rotate_log_file(log_path, max_size=MAX_DEBUG_LOG_SIZE):
    """Rotate a log file if it exceeds max_size. Keeps one .1.jsonl backup."""
    try:
        if log_path.exists() and log_path.stat().st_size > max_size:
            backup = log_path.parent / (log_path.stem + ".1.jsonl")
            if backup.exists():
                backup.unlink()
            log_path.rename(backup)
            print(f"[harness] Rotated {log_path.name} ({max_size // 1024 // 1024}MB limit)")
    except OSError as e:
        print(f"[harness] Log rotation error: {e}")


def _rotate_debug_log():
    """Rotate debug log if it exceeds MAX_DEBUG_LOG_SIZE."""
    rotate_log_file(DEBUG_LOG)


_debug_log_writes = 0


def debug_log(entry):
    """Append a debug entry to the debug log file (full data dump)."""
    global _debug_log_writes
    _debug_log_writes += 1
    if _debug_log_writes % 100 == 0:
        _rotate_debug_log()
    entry["_ts"] = datetime.now(timezone.utc).isoformat()
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Review file I/O
# ---------------------------------------------------------------------------

def read_review_file(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def write_review_file(path, data):
    """Write review data to path as JSON with indent=2."""
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def list_reviews():
    reviews = []
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = read_review_file(path)
            if review is not None:
                reviews.append(review)
    except OSError:
        return []
    reviews.sort(key=lambda r: r.get("completedAt", ""), reverse=True)
    return reviews


def get_review(session_id):
    if not session_id:
        return None
    for review in list_reviews():
        if review.get("sessionId") == session_id:
            return review
    return None


def get_review_path(session_id):
    if not session_id:
        return None
    try:
        for path in REVIEWS_DIR.glob("*.json"):
            review = read_review_file(path)
            if review and review.get("sessionId") == session_id:
                return path
    except OSError:
        return None
    return None


# ---------------------------------------------------------------------------
# Session cost parser
# ---------------------------------------------------------------------------

def parse_session_cost(screen_text):
    """Parse Claude Code session cost from terminal output.
    Checks the last 5 lines where the statusline renders.
    Returns a dollar amount string like "$0.45" or None if not found."""
    if not screen_text:
        return None
    lines = screen_text.splitlines()
    tail = "\n".join(lines[-5:]) if len(lines) > 5 else screen_text
    # Pattern order matters: more specific patterns first
    # Cost: $X.XX
    m = re.search(r"Cost:\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    # 💰$X.XX or 💰 $X.XX
    m = re.search(r"\U0001f4b0\s*(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    # $X.XX block (ccstatusline block cost format)
    m = re.search(r"(\$\d+\.\d{2})\s+block", tail)
    if m:
        return m.group(1)
    # bare $X.XX (catch-all)
    m = re.search(r"(\$\d+\.\d{2})", tail)
    if m:
        return m.group(1)
    return None


# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------

def load_config():
    """Read workspace config from JSON file. Returns normalized config."""
    try:
        with open(CONFIG_FILE, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {"workspaces": {}, "reviewSettings": {}}
        workspaces = data.get("workspaces", {})
        review_settings = data.get("reviewSettings", {})
        if not isinstance(workspaces, dict):
            workspaces = {}
        if not isinstance(review_settings, dict):
            review_settings = {}
        return {
            "workspaces": workspaces,
            "reviewSettings": review_settings,
        }
    except (FileNotFoundError, json.JSONDecodeError, KeyError, OSError):
        return {"workspaces": {}, "reviewSettings": {}}


def save_config(ws_config, review_enabled, review_model, review_backend):
    """Write config to the JSON file."""
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump({
                "workspaces": ws_config,
                "reviewSettings": {
                    "enabled": review_enabled,
                    "model": review_model,
                    "backend": review_backend,
                },
            }, f, indent=2)
    except OSError as e:
        print(f"[harness] config save error: {e}")
