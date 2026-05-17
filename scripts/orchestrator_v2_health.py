#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from cmux_harness import orchestrator_v2_storage as v2
from cmux_harness.orchestrator_v2_runtime import health_payload
from cmux_harness.orchestrator_v2_security import redact_value


def main() -> int:
    payload = health_payload(repo=v2.get_repository())
    print(json.dumps(redact_value(payload), indent=2, sort_keys=True))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
