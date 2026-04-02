from __future__ import annotations

import json

from .claude_cli import run_haiku, run_sonnet
from .objectives import create_task_dir, write_task_file


def build_planning_prompt(goal: str) -> str:
    return f"""You are the planner for this codebase.

Analyze the repository for the following goal:

{goal}

Write your complete implementation plan to ./plan.md.
Do not print the full plan to the terminal. The plan must be written to the file.

Use this exact task format for every task:

## Task N: [title]
- Files: [list of files]
- Depends on: [task numbers or "none"]
- Checkpoints:
  1. [checkpoint]
  2. [checkpoint]
  3. [checkpoint]

Requirements:
- Analyze the codebase before planning.
- Make the plan complete enough to execute without guessing.
- Maximize parallelism where safe. Independent tasks should not depend on each other.
- Keep checkpoints concrete, ordered, and verifiable.
- When the plan is completely written to ./plan.md, exit.
"""


def _build_parsing_prompt(plan_text: str, attempt: int) -> str:
    retry_instruction = ""
    if attempt > 1:
        retry_instruction = (
            "\nThe previous parse was invalid. Re-read the plan carefully and return valid JSON only.\n"
        )

    return f"""Parse the implementation plan into JSON.
Return JSON only. No prose. No markdown fences.
Map dependency numbers like "1" or "Task 1" to task ids like "task-1".
If a task says "Depends on: none", use an empty array.
Keep checkpoints as short strings in order.
{retry_instruction}
Output format:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Fix token expiry check",
      "files": ["TokenManager.swift", "TokenStorage.swift"],
      "dependsOn": [],
      "checkpoints": ["Read current implementation", "Implement fix", "Run tests"]
    }}
  ]
}}

Example 1 input:
## Task 1: Fix token expiry check
- Files: TokenManager.swift, TokenStorage.swift
- Depends on: none
- Checkpoints:
  1. Read current implementation
  2. Implement fix
  3. Run tests

## Task 2: Add regression tests
- Files: TokenManagerTests.swift
- Depends on: 1
- Checkpoints:
  1. Review token expiry changes
  2. Add happy path tests
  3. Add expiry edge case tests

Example 1 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Fix token expiry check",
      "files": ["TokenManager.swift", "TokenStorage.swift"],
      "dependsOn": [],
      "checkpoints": ["Read current implementation", "Implement fix", "Run tests"]
    }},
    {{
      "id": "task-2",
      "title": "Add regression tests",
      "files": ["TokenManagerTests.swift"],
      "dependsOn": ["task-1"],
      "checkpoints": [
        "Review token expiry changes",
        "Add happy path tests",
        "Add expiry edge case tests"
      ]
    }}
  ]
}}

Example 2 input:
## Task 1: Refactor auth config loading
- Files: auth.py
- Depends on: none
- Checkpoints:
  1. Inspect current loading path
  2. Extract shared helper

## Task 2: Update CLI entrypoint
- Files: cli.py, main.py
- Depends on: Task 1
- Checkpoints:
  1. Switch CLI to helper
  2. Verify argument handling

## Task 3: Document new flow
- Files: README.md
- Depends on: none
- Checkpoints:
  1. Describe new config behavior

Example 2 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Refactor auth config loading",
      "files": ["auth.py"],
      "dependsOn": [],
      "checkpoints": ["Inspect current loading path", "Extract shared helper"]
    }},
    {{
      "id": "task-2",
      "title": "Update CLI entrypoint",
      "files": ["cli.py", "main.py"],
      "dependsOn": ["task-1"],
      "checkpoints": ["Switch CLI to helper", "Verify argument handling"]
    }},
    {{
      "id": "task-3",
      "title": "Document new flow",
      "files": ["README.md"],
      "dependsOn": [],
      "checkpoints": ["Describe new config behavior"]
    }}
  ]
}}

Example 3 input:
Plan:

## Task 1: Build parser
- Files: parser.py
- Depends on: none
- Checkpoints:
  1. Parse headings
  2. Parse lists

## Task 2: Wire API
- Files: api.py, server.py
- Depends on: 1
- Checkpoints:
  1. Call parser from API
  2. Return structured response
  3. Add error handling

Example 3 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Build parser",
      "files": ["parser.py"],
      "dependsOn": [],
      "checkpoints": ["Parse headings", "Parse lists"]
    }},
    {{
      "id": "task-2",
      "title": "Wire API",
      "files": ["api.py", "server.py"],
      "dependsOn": ["task-1"],
      "checkpoints": [
        "Call parser from API",
        "Return structured response",
        "Add error handling"
      ]
    }}
  ]
}}

Plan to parse:
{plan_text}
"""


def _normalize_parsed_result(result):
    if isinstance(result, dict):
        return result
    if not isinstance(result, str):
        return None
    try:
        parsed = json.loads(result)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _detect_cycle(task_map):
    visiting = set()
    visited = set()

    def visit(task_id):
        if task_id in visited:
            return False
        if task_id in visiting:
            return True
        visiting.add(task_id)
        for dep_id in task_map[task_id]["dependsOn"]:
            if visit(dep_id):
                return True
        visiting.remove(task_id)
        visited.add(task_id)
        return False

    for task_id in task_map:
        if visit(task_id):
            return True
    return False


def validate_plan(parsed: dict) -> tuple[bool, str]:
    if not isinstance(parsed, dict):
        return False, "parsed plan must be a dict"

    tasks = parsed.get("tasks")
    if "tasks" not in parsed:
        return False, 'missing "tasks" key'
    if not isinstance(tasks, list):
        return False, '"tasks" must be a list'
    if not tasks:
        return False, '"tasks" must not be empty'

    required_fields = {"id", "title", "files", "dependsOn", "checkpoints"}
    task_map = {}
    for index, task in enumerate(tasks, start=1):
        if not isinstance(task, dict):
            return False, f"task {index} must be a dict"

        missing = sorted(required_fields - set(task))
        if missing:
            return False, f"task {index} missing required fields: {', '.join(missing)}"

        task_id = task["id"]
        title = task["title"]
        files = task["files"]
        depends_on = task["dependsOn"]
        checkpoints = task["checkpoints"]

        if not isinstance(task_id, str):
            return False, f"task {index} id must be a string"
        if not isinstance(title, str):
            return False, f"task {task_id} title must be a string"
        if not isinstance(files, list) or not all(isinstance(item, str) for item in files):
            return False, f"task {task_id} files must be a list of strings"
        if not isinstance(depends_on, list) or not all(isinstance(item, str) for item in depends_on):
            return False, f"task {task_id} dependsOn must be a list of strings"
        if not isinstance(checkpoints, list) or not all(isinstance(item, str) for item in checkpoints):
            return False, f"task {task_id} checkpoints must be a list of strings"
        if not checkpoints:
            return False, f"task {task_id} must have at least 1 checkpoint"
        if len(checkpoints) > 5:
            return False, f"task {task_id} must have no more than 5 checkpoints"
        if task_id in task_map:
            return False, f"duplicate task id: {task_id}"
        task_map[task_id] = task

    for task_id, task in task_map.items():
        for dep_id in task["dependsOn"]:
            if dep_id not in task_map:
                return False, f"task {task_id} has invalid dependency: {dep_id}"

    if _detect_cycle(task_map):
        return False, "circular dependency detected"

    return True, ""


def parse_plan(plan_text: str) -> dict:
    attempts = (
        (run_haiku, 1),
        (run_haiku, 2),
        (run_sonnet, 3),
    )
    for runner, attempt in attempts:
        prompt = _build_parsing_prompt(plan_text, attempt)
        parsed = _normalize_parsed_result(runner(prompt))
        is_valid, _error = validate_plan(parsed)
        if is_valid:
            return parsed
    return {"error": "parse_failed", "raw_plan": plan_text}


def _build_spec_content(task: dict) -> str:
    files = task["files"] or []
    checkpoints = task["checkpoints"] or []

    lines = [f"# {task['title']}", "", "## Files"]
    if files:
        lines.extend(f"- {path}" for path in files)
    else:
        lines.append("- None specified")

    lines.extend(["", "## Checkpoints"])
    for index, checkpoint in enumerate(checkpoints, start=1):
        lines.append(f"{index}. {checkpoint}")
    lines.append("")
    return "\n".join(lines)


def plan_to_tasks(parsed: dict, objective_id: str) -> list[dict]:
    tasks = []
    for task in parsed["tasks"]:
        create_task_dir(objective_id, task["id"])
        write_task_file(objective_id, task["id"], "spec.md", _build_spec_content(task))
        tasks.append(
            {
                "id": task["id"],
                "title": task["title"],
                "status": "queued",
                "dependsOn": task["dependsOn"],
                "workspaceId": None,
                "worktreePath": None,
                "worktreeBranch": None,
                "checkpoints": [{"name": cp, "status": "pending"} for cp in task["checkpoints"]],
                "reviewCycles": 0,
                "maxReviewCycles": 5,
                "startedAt": None,
                "completedAt": None,
                "lastProgressAt": None,
            }
        )
    return tasks
