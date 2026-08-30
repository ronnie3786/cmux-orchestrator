# Herdr Workflows

Workflows are the pipelines that Active Work items ride through on the board.
The Buzz ship pipeline (`buzz-feature-work`) is just the first one: any
repeated multi-step process — research spikes, release trains, incident
follow-ups — can be described as a workflow config, applied to the harness,
and tracked on the board with its own stages, gates, trails, and review
documents.

This document is the complete reference for authoring, applying, and
populating workflows. It is written so that an agent can do all of it
end-to-end with the `herdr-active-work` CLI.

---

## 1. Mental model

A **workflow** is a versioned template with two layers:

- **Phases** — the board's regions, left to right (`OPEN`, `BUILD`, …).
  Purely presentational grouping.
- **Stages** — the cards inside those regions. Each stage names the **skill**
  that performs it and whether it is a **human gate** (a checkpoint you must
  approve before the item moves on).

A **work item** (ticket, task, idea) is created *on* a workflow and then
moves forward through its stages — never backward. At each stage the harness
accumulates the who/what/where:

| Association | What it is | How it gets there |
|---|---|---|
| agents | who is attached at that stage, with role + link state | Buzz sync ingestion |
| pi sessions | live/ended terminal sessions (machine, pane) | Buzz sync ingestion |
| buzz threads | the stage's discussion threads (`buzz://` deep links) | Buzz sync ingestion |
| documents | human-review artifacts + the decision made on them | `attach-doc` / `stage-set` |
| activity | the event log | ingestion |

The board renders all of it live over SSE. Items whose current stage is a
pending human gate surface in the needs-you badge; merged items land in the
DONE region.

---

## 2. Workflow config schema

One JSON file per workflow. Shipped defaults live in
`herdr_harness/workflows/`; your own go in
`~/.config/herdr-harness/workflows/` (override the directory with
`HERDR_HARNESS_WORKFLOWS_DIR`). Both are loaded at harness startup; files
that fail validation are skipped with a warning and never crash the server.

```json
{
  "workflow": "research-spike",
  "version": 1,
  "title": "Research spike",
  "description": "Explore a question, prototype the answer, decide.",
  "phases": [
    { "key": "explore", "title": "Explore" },
    { "key": "decide",  "title": "Decide" }
  ],
  "stages": [
    { "key": "survey",    "title": "Survey the landscape", "phase": "explore",
      "skill": "buzz-research-survey", "checkpoint": "none" },
    { "key": "prototype", "title": "Prototype the answer", "phase": "explore",
      "skill": "buzz-prototype",       "checkpoint": "none" },
    { "key": "decision",  "title": "Make the call",        "phase": "decide",
      "skill": "buzz-decision-brief",  "checkpoint": "human" }
  ]
}
```

### Field reference

| Field | Type | Rules |
|---|---|---|
| `workflow` | string | The slug. `^[a-z0-9][a-z0-9-]{1,63}$`. Stable forever — it is how items reference the workflow. |
| `version` | int > 0 | Bump on **any** change to phases or stages. Same version + different content is rejected (409). |
| `title` | string | ≤120 chars, shown on the board's workflow switcher. |
| `description` | string | One sentence. Optional but write it. |
| `phases[]` | array | 1–12 entries, each `{key, title}`. Keys follow the slug rule, must be unique, and every phase must be used by at least one stage. Order = board order, left to right. |
| `stages[]` | array | 2–32 entries. **Array order is the sequence** — there are no explicit sequence numbers to maintain. |
| `stages[].key` | string | Slug rule, unique within the workflow. Stable forever. |
| `stages[].title` | string | Verb-led and human-readable ("Make the call", not "decision-phase-2"). |
| `stages[].phase` | string | Must reference a declared phase key. |
| `stages[].skill` | string | The skill that executes this stage (e.g. `buzz-plan`). The board shows it as the stage kicker. |
| `stages[].checkpoint` | `"none"` \| `"human"` | `human` stages render as gates (`HUMAN GATE`), demand your approval, and surface in needs-you when pending. |
| `stages[].next` | string[] | Optional. Allowed forward transitions. Defaults to the single following stage. Every entry must reference a **later** stage (forward-only). The final stage must have no `next` — it is the terminal stage; completing it is what lets an item go `done`. |

Unknown keys anywhere are rejected — typos fail loudly at validation, not
silently at render time.

### Design guidance

- **5–9 stages is the sweet spot.** A stage is a unit one agent (or you) can
  own; anything smaller is activity *within* a stage.
- **Gates are where you want to be interrupted.** Every `checkpoint: human`
  becomes a needs-you interruption — spend them deliberately.
- **`next` is for real branches only.** A linear workflow should omit it
  everywhere. Use it when a stage can legitimately skip ahead (e.g. a pure
  refactor jumping past a proof stage).
- Don't encode people or machines in the config — agents, sessions, and
  machines attach to *items* at runtime.

---

## 3. Authoring → applying → verifying

```bash
# 1. Write the file (agent or human)
$EDITOR ~/.config/herdr-harness/workflows/research-spike.json

# 2. Structural check without touching the server
herdr-active-work workflow-apply --file ~/.config/herdr-harness/workflows/research-spike.json --validate

# 3. Apply (validates server-side, creates the versioned template)
herdr-active-work workflow-apply --file ~/.config/herdr-harness/workflows/research-spike.json

# 4. Confirm
herdr-active-work workflow-list
herdr-active-work workflow-show research-spike
```

Applying is idempotent: re-applying identical content is a no-op; changed
content under the same version is refused with
`workflow_version_conflict` — bump `version` and apply again. Existing items
keep riding the version they were created on; new items get the latest.

The harness also applies every config file it finds at startup, so a file
dropped into the workflows directory is live after the next restart even
without the CLI.

API equivalents (manage token):
`GET /api/v1/active-work/workflows` · `GET /api/v1/active-work/workflows/{slug}` ·
`POST /api/v1/active-work/workflows` (body = the config JSON).

---

## 4. Associating work with a workflow

```bash
# New item on a specific workflow (defaults to buzz-feature-work when omitted)
herdr-active-work create --title "Evaluate local STT models" --kind task --workflow research-spike

# Move it forward (stage keys come from workflow-show; transitions are forward-only)
herdr-active-work move IOSDOX-27812 --to prototype --note "Survey brief approved"

# Approve a human gate while advancing
herdr-active-work move IOSDOX-27812 --to decision --checkpoint approved
```

Jira-connected items (`connect`, `candidates`) behave the same — the workflow
just determines which stages they ride. An item's terminal stage is its
workflow's last stage; `done` is only accepted there.

---

## 5. Populating stage content

Two write paths, by producer:

1. **Buzz sync (automatic).** The reconciler ingests agents, sessions,
   threads, states, and activity via `POST /api/v1/active-work/ingestions`.
   You normally never call this by hand.
2. **Direct stage writes (skills, agents, you).**
   `PATCH /api/v1/active-work/items/{id}/stages/{stage_key}` with
   `{summary?, content?}` — content is deep-merged (never deletes), bounded
   at 256 KB per stage. The CLI fronts it:

```bash
# Set/replace the stage summary
herdr-active-work stage-set AGENTIC-575 --stage implement --summary "Middleware landed; scoped tests green"

# Merge arbitrary structured content
herdr-active-work stage-set AGENTIC-575 --stage implement --content-file ./notes.json
```

### Review documents (the convention that powers the board's doc rows)

When a buzz skill produces an artifact that a **human reviews** — a plan
approval page, an event map, a triage brief — attach it to the stage that
produced it. Not every file: only what carries a decision.

```bash
herdr-active-work attach-doc AGENTIC-575 \
  --stage plan \
  --id plan-approval \
  --title plan-approval.html \
  --kind html \
  --skill buzz-plan \
  --status approved \
  --by Ronnie \
  --url "https://rocketbot.tail1db61d.ts.net:8475/tickets/AGENTIC-575/plan-approval.html"
```

| Field | Values / meaning |
|---|---|
| `--id` | Stable per stage; re-attaching the same id updates the record (merge semantics). |
| `--kind` | `html`, `json`, `md`, `other`. |
| `--status` | `awaiting-you` (surfaces the gate), `approved`, `changes_requested`, `info` (supporting artifact, no decision). |
| `--by` / `--at` | Who decided, when (`--at` defaults to now, UTC). Update the doc from `awaiting-you` to its decision when you rule on it. |
| `--url` | Where the artifact lives. The board's **Open** action uses it. |

Documents live at `stage.content.documents.<id>` in the projection, so any
other tooling can read them straight off `GET /api/v1/active-work`.

### The skill recipe (copy-paste for buzz-* skills)

At the end of a stage that produced a reviewable artifact:

```bash
herdr-active-work attach-doc "$TICKET" --stage "$STAGE" \
  --id "$DOC_ID" --title "$FILENAME" --kind html \
  --skill "$SKILL_NAME" --status awaiting-you --url "$DOC_URL"
```

After the human rules on it:

```bash
herdr-active-work attach-doc "$TICKET" --stage "$STAGE" \
  --id "$DOC_ID" --title "$FILENAME" --kind html \
  --skill "$SKILL_NAME" --status approved --by Ronnie
```

---

## 6. How the board renders your config

| Config | Board |
|---|---|
| `phases` | The region rectangles, left to right, uppercase titles. |
| `stages` order | Card order inside each region; the sequence trails follow. |
| `checkpoint: human` | `HUMAN GATE` tag; pending → needs-you badge + gate capsule with the approve action. |
| `next` | Which forward transitions the approve action offers (first entry is the default). |
| `skill` | The mono kicker on the stage card and the skill attribution on documents. |
| terminal stage | Completing it enables done → the item's trail extends into the DONE region. |

Multiple workflows with active items produce a **workflows** switcher at the
top of the board sidebar; each workflow gets its own world.

---

## 7. Gotchas

- **Forward-only, always.** There is no backward transition; model rework as
  a `changes_requested` checkpoint on the current stage, not a move back.
- **Version bumps are cheap; silent edits are impossible.** The harness
  refuses changed content under an existing version — this is what keeps
  in-flight items coherent.
- **Stage keys are forever.** Renaming a key in a new version orphans
  nothing (old items keep their old version) but breaks your muscle memory
  and any scripts that hardcode keys. Prefer changing titles.
- **Content merges never delete.** To retire a document, update it with
  `--status info`; there is no removal primitive by design.
- The CLI validates structure locally with `--validate`, but the server is
  the authority — apply errors carry a JSON path
  (e.g. `stages[3].next[0]`) pointing at the offending field.

---

## 8. Quick reference

```bash
herdr-active-work workflow-list
herdr-active-work workflow-show SLUG [--wf-version N]
herdr-active-work workflow-apply --file PATH [--validate]
herdr-active-work create --title T [--kind feature|task|idea] [--workflow SLUG]
herdr-active-work move REF --to STAGE [--checkpoint approved|changes_requested] [--note TEXT]
herdr-active-work stage-set REF --stage KEY [--summary TEXT] [--content-file PATH|-]
herdr-active-work attach-doc REF --stage KEY --id ID --title T --kind K --skill S --status ST [--by NAME] [--url URL] [--at ISO]
```

Board: `{harness}/board/` (live) · `{harness}/board/?demo=1` (design demo).
Contract details: `herdr_harness/README.md`. Operator runbook:
`HERDR_HARNESS.md`.
