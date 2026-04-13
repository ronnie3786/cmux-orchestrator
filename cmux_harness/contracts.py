from __future__ import annotations

import re


_SECTION_PATTERNS = {
    "acceptanceCriteria": re.compile(
        r"^##\s*Acceptance Criteria\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    ),
    "buildVerification": re.compile(
        r"^##\s*Build Verification\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    ),
    "functionalTestHints": re.compile(
        r"^##\s*Functional Test Hints\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    ),
    "passFailThreshold": re.compile(
        r"^##\s*Pass/Fail Threshold\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    ),
}

_MAESTRO_RUNTIME_HINT_RE = re.compile(
    r"\b("
    r"maestro|ios|android|mobile|screen|button|tap|swipe|scroll|text field|textfield|"
    r"dialog|modal|sheet|toast|navigate|navigation|launch app|open app|assertvisible"
    r")\b",
    re.IGNORECASE,
)
_NON_RUNTIME_TASK_RE = re.compile(
    r"\b("
    r"jira|ticket|issue\b|github|pull request|draft pr|commit|push|branch|docs?|documentation|"
    r"claude\.md|readme|comment"
    r")\b",
    re.IGNORECASE,
)


def build_contract_prompt(task):
    """Build a prompt asking Claude to generate a sprint contract from a task."""
    title = str(task.get("title") or "").strip()
    user_story = str(task.get("userStory") or "").strip()
    deliverables = [str(item).strip() for item in task.get("deliverables", []) if str(item).strip()]
    checkpoints = task.get("checkpoints", [])

    checkpoint_lines = []
    for checkpoint in checkpoints:
        if isinstance(checkpoint, dict):
            name = str(checkpoint.get("name") or "").strip()
        else:
            name = str(checkpoint).strip()
        if name:
            checkpoint_lines.append(f"- {name}")

    deliverable_block = "\n".join(f"- {item}" for item in deliverables) or "- None provided"
    checkpoint_block = "\n".join(checkpoint_lines) or "- None provided"

    return f"""You are drafting a sprint contract for a coding task.

Task title: {title or "Untitled task"}

User Story:
{user_story or "Not provided"}

Deliverables:
{deliverable_block}

Checkpoints:
{checkpoint_block}

Write the sprint contract in markdown using exactly these sections and headings:

## Acceptance Criteria
Provide a numbered list of specific, testable behaviors.

## Build Verification
If the task changes repository code or config that should be validated locally, include `/exp-project-run`.
If that command is not applicable, give the concrete verification step that fits the task and say why `/exp-project-run` is not needed.

## Functional Test Hints
Suggest practical end-to-end validation steps. Use Maestro only when the task changes a user-facing app flow that Maestro can realistically exercise. For repo hygiene, docs, Jira, PR, or other non-runtime tasks, give the appropriate manual or CLI verification instead.

## Pass/Fail Threshold
State the minimum bar for accepting or rejecting the task result.

Keep the contract concrete and tied to the task inputs. Return markdown only.
"""


def build_contract_evaluator_prompt(task, contract_text):
    """Build a prompt asking an evaluator to validate a generated contract."""
    title = str(task.get("title") or "").strip()
    user_story = str(task.get("userStory") or "").strip()
    deliverables = [str(item).strip() for item in task.get("deliverables", []) if str(item).strip()]
    checkpoints = task.get("checkpoints", [])

    checkpoint_lines = []
    for checkpoint in checkpoints:
        if isinstance(checkpoint, dict):
            name = str(checkpoint.get("name") or "").strip()
        else:
            name = str(checkpoint).strip()
        if name:
            checkpoint_lines.append(f"- {name}")

    deliverable_block = "\n".join(f"- {item}" for item in deliverables) or "- None provided"
    checkpoint_block = "\n".join(checkpoint_lines) or "- None provided"

    return f"""You are the evaluator for a sprint contract proposed by another AI agent.

Task title: {title or "Untitled task"}

User Story:
{user_story or "Not provided"}

Deliverables:
{deliverable_block}

Checkpoints:
{checkpoint_block}

Draft contract:
{contract_text.strip() or "(empty)"}

Decide whether this contract is good enough to hand to a coding worker.

Fail the contract if any of these are true:
- It does not match the task title, user story, deliverables, or checkpoints
- Acceptance criteria are vague, partial, or not testable end to end
- Build verification is missing, too weak, or inappropriate for the task
- Functional test hints are not useful for validating the task, or they propose UI automation for a task that is not a runtime/user-flow change
- Pass/fail threshold is vague or lenient
- Required sections are missing

Respond with JSON only using this shape:
{{
  "verdict": "pass" | "fail",
  "summary": "one sentence",
  "issues": ["specific issue 1", "specific issue 2"]
}}
"""


def build_contract_revision_prompt(task, contract_text, evaluation):
    """Build a prompt asking the generator to revise a contract after evaluator feedback."""
    issues = evaluation.get("issues") if isinstance(evaluation, dict) else []
    issue_block = "\n".join(f"- {str(item).strip()}" for item in issues if str(item).strip()) or "- Fix the evaluator concerns."
    summary = str((evaluation or {}).get("summary") or "").strip()

    return f"""{build_contract_prompt(task)}

Evaluator summary:
{summary or "The evaluator rejected the previous draft."}

Evaluator issues:
{issue_block}

Current contract:
{contract_text.strip() or "(empty)"}

Revise the entire contract to address every evaluator issue.
Return markdown only.
"""


def parse_contract(text):
    """Parse contract markdown. Returns dict with sections or None on failure."""
    if not isinstance(text, str) or not text.strip():
        return None

    parsed = {}
    for key, pattern in _SECTION_PATTERNS.items():
        match = pattern.search(text)
        if not match:
            return None
        parsed[key] = match.group("body").strip()

    return parsed


def parse_contract_evaluation(value):
    """Normalize an evaluator response into a verdict/summary/issues dict."""
    if not isinstance(value, dict):
        return None

    verdict = str(value.get("verdict") or "").strip().lower()
    if verdict not in {"pass", "fail"}:
        return None

    issues = value.get("issues")
    if not isinstance(issues, list):
        issues = []

    cleaned_issues = [str(item).strip() for item in issues if str(item).strip()]
    return {
        "verdict": verdict,
        "summary": str(value.get("summary") or "").strip(),
        "issues": cleaned_issues,
    }


def should_run_maestro(task, contract_text):
    """Return True when the task/contract suggests a real runtime flow for Maestro."""
    parsed = parse_contract(contract_text) if contract_text else None
    hints_text = ""
    criteria_text = ""
    if isinstance(parsed, dict):
        hints_text = str(parsed.get("functionalTestHints") or "")
        criteria_text = str(parsed.get("acceptanceCriteria") or "")

    if _MAESTRO_RUNTIME_HINT_RE.search(hints_text):
        return True

    task_parts = []
    if isinstance(task, dict):
        task_parts.append(str(task.get("title") or ""))
        task_parts.append(str(task.get("userStory") or ""))
        deliverables = task.get("deliverables") or []
        if isinstance(deliverables, list):
            task_parts.extend(str(item) for item in deliverables)

    combined = "\n".join(part for part in [criteria_text, hints_text, *task_parts] if part.strip())
    if not combined.strip():
        return False
    if _NON_RUNTIME_TASK_RE.search(combined) and not _MAESTRO_RUNTIME_HINT_RE.search(combined):
        return False
    return bool(_MAESTRO_RUNTIME_HINT_RE.search(criteria_text) or _MAESTRO_RUNTIME_HINT_RE.search(combined))
