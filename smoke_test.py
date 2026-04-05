#!/usr/bin/env python3
"""End-to-end smoke test for the orchestrator pipeline.

Runs the full flow: create objective → start → monitor messages → report.
Does NOT start a web server — calls orchestrator methods directly.
"""

import json
import os
import sys
import time
import threading
from datetime import datetime, timezone
from pathlib import Path

# Add project root to path
sys.path.insert(0, os.path.dirname(__file__))

from cmux_harness.engine import HarnessEngine
from cmux_harness.orchestrator import Orchestrator
from cmux_harness import objectives

REPORT_PATH = Path(__file__).parent / "SMOKE_TEST_REPORT.md"
PROJECT_DIR = os.path.expanduser("~/projects/ai-101-landing")
GOAL = "Add a dark mode toggle button to the navigation bar. The toggle should persist the user's preference in localStorage and apply a 'dark' class to the document element. Create a new DarkModeToggle component in src/app/components/ and integrate it into the existing layout."

def log(msg, report_lines):
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    report_lines.append(line)

def main():
    report = []
    log("=" * 60, report)
    log("ORCHESTRATOR SMOKE TEST", report)
    log(f"Project: {PROJECT_DIR}", report)
    log(f"Goal: {GOAL}", report)
    log("=" * 60, report)

    # Step 1: Verify project exists
    if not os.path.isdir(PROJECT_DIR):
        log(f"FAIL: Project dir not found: {PROJECT_DIR}", report)
        write_report(report)
        return

    log("Step 1: Project directory verified ✓", report)

    # Step 2: Create objective
    log("\nStep 2: Creating objective...", report)
    try:
        objective = objectives.create_objective(GOAL, PROJECT_DIR, "main")
        obj_id = objective["id"]
        log(f"  Objective created: {obj_id}", report)
        log(f"  Status: {objective['status']}", report)
        log(f"  Dir: {objectives.get_objective_dir(obj_id)}", report)
    except Exception as e:
        log(f"FAIL: Could not create objective: {e}", report)
        write_report(report)
        return

    # Step 3: Initialize engine + orchestrator
    log("\nStep 3: Initializing engine...", report)
    try:
        engine = HarnessEngine()
        orchestrator = engine.orchestrator
        log(f"  Engine initialized ✓", report)
        log(f"  Orchestrator ready ✓", report)
    except Exception as e:
        log(f"FAIL: Engine init failed: {e}", report)
        write_report(report)
        return

    # Step 4: Start objective
    log("\nStep 4: Starting objective...", report)
    try:
        started = orchestrator.start_objective(obj_id)
        log(f"  start_objective returned: {started}", report)
        if not started:
            log("FAIL: start_objective returned False", report)
            write_report(report)
            return
        log(f"  Active objective: {orchestrator.get_active_objective_id()}", report)
    except Exception as e:
        log(f"FAIL: start_objective raised: {e}", report)
        import traceback
        log(traceback.format_exc(), report)
        write_report(report)
        return

    # Step 5: Monitor progress
    log("\nStep 5: Monitoring pipeline (max 10 minutes)...", report)
    log("  Polling messages every 10 seconds...\n", report)

    start_time = time.time()
    max_duration = 2400  # 40 minutes
    last_msg_count = 0
    poll_count = 0
    seen_statuses = set()

    while time.time() - start_time < max_duration:
        poll_count += 1
        elapsed = time.time() - start_time

        # Run orchestrator poll_tasks to process approvals, completions, stuck detection
        try:
            if hasattr(orchestrator, 'poll_tasks') and orchestrator.get_active_objective_id():
                orchestrator.poll_tasks(obj_id)
        except Exception as e:
            log(f"  [{elapsed:.0f}s] poll_tasks error: {e}", report)

        # Read objective state
        obj = objectives.read_objective(obj_id)
        status = obj.get("status", "unknown") if obj else "NOT FOUND"
        tasks = obj.get("tasks", []) if obj else []
        task_statuses = {t["id"]: t.get("status", "?") for t in tasks}

        if status not in seen_statuses:
            seen_statuses.add(status)
            log(f"  [{elapsed:.0f}s] Objective status changed to: {status}", report)

        # Read messages
        messages = orchestrator.get_messages(obj_id)
        if len(messages) > last_msg_count:
            for msg in messages[last_msg_count:]:
                msg_type = msg.get("type", "?")
                content = msg.get("content", "")[:120]
                log(f"  [{elapsed:.0f}s] MSG [{msg_type}]: {content}", report)
            last_msg_count = len(messages)

        # Log task statuses periodically
        if poll_count % 6 == 0 and tasks:  # Every 60 seconds
            log(f"  [{elapsed:.0f}s] Task statuses: {json.dumps(task_statuses)}", report)

        # Check for terminal states
        if status in ("completed", "failed"):
            log(f"\n  Pipeline reached terminal state: {status}", report)
            break

        # Check if all tasks completed
        if tasks and all(t.get("status") == "completed" for t in tasks):
            log(f"\n  All tasks completed!", report)
            break

        # Check for stuck planning (no tasks after 3 min)
        if elapsed > 180 and not tasks and status == "planning":
            log(f"\n  WARNING: Still planning after 3 minutes, no tasks yet", report)

        time.sleep(10)

    # Step 6: Final report
    elapsed_total = time.time() - start_time
    log(f"\n{'=' * 60}", report)
    log("FINAL STATE", report)
    log(f"{'=' * 60}", report)

    obj = objectives.read_objective(obj_id)
    if obj:
        log(f"  Objective status: {obj.get('status')}", report)
        log(f"  Total time: {elapsed_total:.0f}s ({elapsed_total/60:.1f} min)", report)
        log(f"  Total messages: {len(orchestrator.get_messages(obj_id))}", report)
        tasks = obj.get("tasks", [])
        log(f"  Tasks: {len(tasks)}", report)
        for t in tasks:
            log(f"    - {t.get('id')}: {t.get('title', '?')} [{t.get('status')}] (review cycles: {t.get('reviewCycles', 0)})", report)

        # Check filesystem artifacts
        obj_dir = objectives.get_objective_dir(obj_id)
        log(f"\n  Filesystem artifacts:", report)
        for task in tasks:
            tid = task["id"]
            task_dir = obj_dir / "tasks" / tid
            for fname in ["spec.md", "context.md", "progress.md", "result.md", "review.json"]:
                fpath = task_dir / fname
                exists = fpath.exists()
                size = fpath.stat().st_size if exists else 0
                log(f"    {tid}/{fname}: {'EXISTS' if exists else 'MISSING'} ({size} bytes)", report)

        # Dump messages
        log(f"\n  Full message log:", report)
        for msg in orchestrator.get_messages(obj_id):
            log(f"    [{msg.get('type')}] {msg.get('content', '')[:200]}", report)
    else:
        log("  Objective not found on disk!", report)

    # Check for plan.md in project dir
    plan_path = os.path.join(PROJECT_DIR, "plan.md")
    if os.path.exists(plan_path):
        plan_size = os.path.getsize(plan_path)
        log(f"\n  plan.md in project dir: EXISTS ({plan_size} bytes)", report)
        log(f"  First 500 chars:", report)
        with open(plan_path) as f:
            log(f"  {f.read(500)}", report)
    else:
        log(f"\n  plan.md in project dir: MISSING", report)

    log(f"\n{'=' * 60}", report)
    
    # Determine pass/fail
    final_status = obj.get("status", "unknown") if obj else "unknown"
    if final_status == "completed":
        log("RESULT: PASS ✅", report)
    elif final_status == "failed":
        log("RESULT: FAIL ❌ (pipeline failed)", report)
    elif elapsed_total >= max_duration:
        log("RESULT: TIMEOUT ⏰ (10 min exceeded)", report)
    else:
        log(f"RESULT: INCOMPLETE ⚠️ (status: {final_status})", report)

    write_report(report)


def write_report(report):
    with open(REPORT_PATH, "w") as f:
        f.write("# Orchestrator Smoke Test Report\n\n")
        f.write(f"*Generated: {datetime.now().isoformat()}*\n\n")
        f.write("```\n")
        f.write("\n".join(report))
        f.write("\n```\n")
    print(f"\nReport written to: {REPORT_PATH}")


if __name__ == "__main__":
    main()
