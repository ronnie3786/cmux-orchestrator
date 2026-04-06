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
Always include `/exp-project-run`.

## Functional Test Hints
Suggest practical Maestro flow ideas to validate the task end to end.

## Pass/Fail Threshold
State the minimum bar for accepting or rejecting the task result.

Keep the contract concrete and tied to the task inputs. Return markdown only.
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
