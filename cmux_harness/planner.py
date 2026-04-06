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
- User Story: [what the user can do after this task]
- Deliverables: [screens, features, behaviors this task produces]
- Depends on: [task numbers or "none"]
- Checkpoints:
  1. [checkpoint focused on WHAT not HOW]
  2. [checkpoint focused on WHAT not HOW]
  3. [checkpoint focused on WHAT not HOW]

CRITICAL PLANNING RULES:

1. **MAXIMIZE PARALLELISM.** Most tasks should have NO dependencies.
   - Bad: Task 1 → Task 2 → Task 3 → Task 4 (sequential chain)
   - Good: Tasks 1, 2, 3 run in parallel; Task 4 depends on 1+2
   - Only add a dependency when a task literally cannot start without another task's output.
   - Split tasks around independent deliverables so parallel work is obvious.

2. **NO dependency chains longer than 2.** If Task 3 depends on Task 2 which depends on Task 1, restructure. Either merge tasks or remove unnecessary dependencies.

3. **SMALL, FOCUSED TASKS.** Each task should produce a clear user-facing outcome. If a task bundles too many features or behaviors, split it.

4. **STAY HIGH-LEVEL.** Stay focused on WHAT should be built, not HOW.
   - Do not specify file paths, function names, or implementation details.
   - The worker will figure out the implementation.

5. **SELF-CONTAINED TASKS.** Each task must be completable and testable in isolation. Don't create tasks that only make sense after another task runs (unless explicitly listed as a dependency).

6. Keep checkpoints concrete, ordered, verifiable, and focused on outcomes rather than code changes.
- Analyze the codebase before planning.
- Make the plan complete enough to execute without guessing.
- Aim for 3-6 tasks total. More than 6 usually means tasks are too granular.
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
      "userStory": "Users stay signed in until their token actually expires.",
      "deliverables": ["Accurate token expiry handling", "Stable token refresh behavior"],
      "dependsOn": [],
      "checkpoints": ["Read current implementation", "Implement fix", "Run tests"]
    }}
  ]
}}

Example 1 input:
## Task 1: Fix token expiry check
- User Story: Users stay signed in until their token actually expires.
- Deliverables: Accurate token expiry handling, Stable token refresh behavior
- Depends on: none
- Checkpoints:
  1. Token expiry is evaluated correctly
  2. Token refresh behavior stays reliable
  3. Regression coverage confirms the flow

## Task 2: Add regression tests
- User Story: Users are protected from future token expiry regressions.
- Deliverables: Regression test coverage for token expiry edge cases
- Depends on: 1
- Checkpoints:
  1. Happy path token expiry coverage exists
  2. Expiry edge cases are covered
  3. The regression suite documents expected behavior

Example 1 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Fix token expiry check",
      "userStory": "Users stay signed in until their token actually expires.",
      "deliverables": ["Accurate token expiry handling", "Stable token refresh behavior"],
      "dependsOn": [],
      "checkpoints": [
        "Token expiry is evaluated correctly",
        "Token refresh behavior stays reliable",
        "Regression coverage confirms the flow"
      ]
    }},
    {{
      "id": "task-2",
      "title": "Add regression tests",
      "userStory": "Users are protected from future token expiry regressions.",
      "deliverables": ["Regression test coverage for token expiry edge cases"],
      "dependsOn": ["task-1"],
      "checkpoints": [
        "Happy path token expiry coverage exists",
        "Expiry edge cases are covered",
        "The regression suite documents expected behavior"
      ]
    }}
  ]
}}

Example 2 input:
## Task 1: Refactor auth config loading
- User Story: Authentication settings load consistently across environments.
- Deliverables: Reliable auth config loading behavior
- Depends on: none
- Checkpoints:
  1. Auth config loads consistently
  2. Shared loading behavior is unified

## Task 2: Update CLI entrypoint
- User Story: CLI users can start the app with the updated auth loading flow.
- Deliverables: CLI startup works with the new auth config flow
- Depends on: Task 1
- Checkpoints:
  1. CLI startup uses the updated auth flow
  2. Argument handling still behaves correctly

## Task 3: Document new flow
- User Story: Developers understand how auth config now loads.
- Deliverables: Updated documentation for auth config behavior
- Depends on: none
- Checkpoints:
  1. Documentation explains the new auth config behavior

Example 2 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Refactor auth config loading",
      "userStory": "Authentication settings load consistently across environments.",
      "deliverables": ["Reliable auth config loading behavior"],
      "dependsOn": [],
      "checkpoints": ["Auth config loads consistently", "Shared loading behavior is unified"]
    }},
    {{
      "id": "task-2",
      "title": "Update CLI entrypoint",
      "userStory": "CLI users can start the app with the updated auth loading flow.",
      "deliverables": ["CLI startup works with the new auth config flow"],
      "dependsOn": ["task-1"],
      "checkpoints": ["CLI startup uses the updated auth flow", "Argument handling still behaves correctly"]
    }},
    {{
      "id": "task-3",
      "title": "Document new flow",
      "userStory": "Developers understand how auth config now loads.",
      "deliverables": ["Updated documentation for auth config behavior"],
      "dependsOn": [],
      "checkpoints": ["Documentation explains the new auth config behavior"]
    }}
  ]
}}

Example 3 input:
Plan:

## Task 1: Build parser
- User Story: Users get structured data from parser input.
- Deliverables: Parser behavior that extracts headings and lists
- Depends on: none
- Checkpoints:
  1. Headings are parsed into structured output
  2. Lists are parsed into structured output

## Task 2: Wire API
- User Story: API clients receive parsed output through the service.
- Deliverables: API endpoint that returns parser results with error handling
- Depends on: 1
- Checkpoints:
  1. API responses include parsed output
  2. Structured responses are returned to clients
  3. Error handling covers parser failures

Example 3 output:
{{
  "tasks": [
    {{
      "id": "task-1",
      "title": "Build parser",
      "userStory": "Users get structured data from parser input.",
      "deliverables": ["Parser behavior that extracts headings and lists"],
      "dependsOn": [],
      "checkpoints": ["Headings are parsed into structured output", "Lists are parsed into structured output"]
    }},
    {{
      "id": "task-2",
      "title": "Wire API",
      "userStory": "API clients receive parsed output through the service.",
      "deliverables": ["API endpoint that returns parser results with error handling"],
      "dependsOn": ["task-1"],
      "checkpoints": [
        "API responses include parsed output",
        "Structured responses are returned to clients",
        "Error handling covers parser failures"
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

    required_fields = {"id", "title", "userStory", "deliverables", "dependsOn", "checkpoints"}
    task_map = {}
    for index, task in enumerate(tasks, start=1):
        if not isinstance(task, dict):
            return False, f"task {index} must be a dict"

        missing = sorted(required_fields - set(task))
        if missing:
            return False, f"task {index} missing required fields: {', '.join(missing)}"

        task_id = task["id"]
        title = task["title"]
        user_story = task["userStory"]
        deliverables = task["deliverables"]
        depends_on = task["dependsOn"]
        checkpoints = task["checkpoints"]

        if not isinstance(task_id, str):
            return False, f"task {index} id must be a string"
        if not isinstance(title, str):
            return False, f"task {task_id} title must be a string"
        if not isinstance(user_story, str) or not user_story.strip():
            return False, f"task {task_id} userStory must be a non-empty string"
        if not isinstance(deliverables, list) or not deliverables or not all(
            isinstance(item, str) and item.strip() for item in deliverables
        ):
            return False, f"task {task_id} deliverables must be a non-empty list of strings"
        if not isinstance(depends_on, list) or not all(isinstance(item, str) for item in depends_on):
            return False, f"task {task_id} dependsOn must be a list of strings"
        if not isinstance(checkpoints, list) or not all(isinstance(item, str) for item in checkpoints):
            return False, f"task {task_id} checkpoints must be a list of strings"
        if not checkpoints:
            return False, f"task {task_id} must have at least 1 checkpoint"
        if len(checkpoints) > 10:
            return False, f"task {task_id} must have no more than 10 checkpoints"
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
        (run_sonnet, 1),
        (run_haiku, 2),
        (run_haiku, 3),
    )
    for runner, attempt in attempts:
        prompt = _build_parsing_prompt(plan_text, attempt)
        parsed = _normalize_parsed_result(runner(prompt))
        is_valid, _error = validate_plan(parsed)
        if is_valid:
            return parsed
    return {"error": "parse_failed", "raw_plan": plan_text}


def _build_spec_content(task: dict) -> str:
    deliverables = task["deliverables"] or []
    user_story = task["userStory"]
    checkpoints = task["checkpoints"] or []
    depends_on = task.get("dependsOn", [])

    lines = [f"# {task['title']}", ""]

    lines.append("## User Story")
    lines.append("")
    lines.append(user_story)
    lines.append("")

    lines.append("## Deliverables")
    lines.append("")
    lines.extend(f"- {item}" for item in deliverables)
    lines.append("")

    lines.append("**DO NOT:**")
    lines.append("- Install new dependencies or packages")
    lines.append("- Refactor code unrelated to this task")
    lines.append("- Implement features beyond what this spec describes")
    lines.append("- Drift into implementation details that do not serve the user story")
    lines.append("")
    lines.append("Your task is to implement these deliverables. Stay focused on the user story.")
    lines.append("")

    if depends_on:
        lines.append("## Dependencies")
        lines.append("")
        lines.append("This task depends on completed work from: " + ", ".join(depends_on))
        lines.append("Read ./context.md for details on what was done in those tasks.")
        lines.append("")

    lines.append("## Checkpoints")
    lines.append("")
    for index, checkpoint in enumerate(checkpoints, start=1):
        lines.append(f"{index}. {checkpoint}")
    lines.append("")

    lines.append("## Completion Criteria")
    lines.append("")
    lines.append("Your task is done when ALL deliverables and checkpoints above are completed.")
    lines.append("Write result.md describing exactly what you changed and why.")
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
                "userStory": task["userStory"],
                "deliverables": list(task["deliverables"]),
                "status": "queued",
                "dependsOn": task["dependsOn"],
                "workspaceId": None,
                "worktreePath": None,
                "checkpoints": [{"name": cp, "status": "pending"} for cp in task["checkpoints"]],
                "reviewCycles": 0,
                "maxReviewCycles": 3,
                "startedAt": None,
                "completedAt": None,
                "lastProgressAt": None,
            }
        )
    return tasks
