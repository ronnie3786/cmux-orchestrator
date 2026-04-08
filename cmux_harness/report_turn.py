#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def _parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Finalize a cmux workspace chat turn.")
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--turn-id", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--file", dest="file_path")
    parser.add_argument("--source", default="callback-helper")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--stdin", action="store_true")
    return parser.parse_args(argv)


def _read_content(args) -> str:
    if args.stdin:
        return sys.stdin.read()
    if args.file_path:
        return Path(args.file_path).read_text(encoding="utf-8")
    raise ValueError("either --file or --stdin is required")


def _finalize(server_url: str, workspace_id: str, turn_id: str, token: str, content: str, *, source: str, timeout: float):
    url = server_url.rstrip("/") + f"/api/workspaces/{workspace_id}/turns/{turn_id}/finalize"
    payload = json.dumps(
        {
            "token": token,
            "content": content,
            "source": source,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    if body:
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {}
        if isinstance(parsed, dict) and not parsed.get("ok", False):
            raise RuntimeError(parsed.get("error") or "turn finalize rejected")


def main(argv=None) -> int:
    args = _parse_args(argv)
    try:
        content = _read_content(args)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if not str(content or "").strip():
        print("content required", file=sys.stderr)
        return 2

    attempts = max(1, int(args.retries) + 1)
    last_error = None
    for attempt in range(attempts):
        try:
            _finalize(
                args.server_url,
                args.workspace_id,
                args.turn_id,
                args.token,
                content,
                source=args.source,
                timeout=float(args.timeout),
            )
            return 0
        except (OSError, RuntimeError, urllib.error.URLError) as exc:
            last_error = exc
            if attempt < attempts - 1:
                time.sleep(0.5)
    print(str(last_error or "turn finalize failed"), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
