// Buzz Trail v2 dataset — fleshed out to exercise the full harness model:
// machines/floors, setup states, jira candidates, all four checkpoint states,
// a done item, the full agent roster, channels + unscoped threads, handoff
// commands. Field names still mirror herdr_harness/active_work_store.py.

const PIPELINE = {
  id: "pipeline_buzz_feature_work_v1",
  slug: "buzz-feature-work",
  title: "Buzz feature work",
  stages: [
    { stage_key: "start-ticket",          sequence: 1, phase_key: "open",  title: "Start",        skill_name: "buzz-start-ticket",          checkpoint_kind: "none"  },
    { stage_key: "plan",                  sequence: 2, phase_key: "open",  title: "Plan",         skill_name: "buzz-plan",                  checkpoint_kind: "human" },
    { stage_key: "implement",             sequence: 3, phase_key: "build", title: "Implement",    skill_name: "buzz-implement",             checkpoint_kind: "none"  },
    { stage_key: "architect-code-review", sequence: 4, phase_key: "build", title: "Agent review", skill_name: "buzz-architect-code-review", checkpoint_kind: "none"  },
    { stage_key: "proof",                 sequence: 5, phase_key: "prove", title: "Proof",        skill_name: "buzz-proof",                 checkpoint_kind: "human" },
    { stage_key: "code-review-pre-pr",    sequence: 6, phase_key: "prove", title: "Pre-PR",       skill_name: "buzz-code-review-pre-pr",    checkpoint_kind: "human" },
    { stage_key: "pr",                    sequence: 7, phase_key: "ship",  title: "PR",           skill_name: "buzz-pr",                    checkpoint_kind: "human" },
    { stage_key: "pr-triage",             sequence: 8, phase_key: "ship",  title: "Triage",       skill_name: "buzz-pr-triage",             checkpoint_kind: "none"  }
  ]
};

const MACHINES = {
  "rocketbot": { name: "rocketbot", label: "local",  status: "online" },
  "devbox":    { name: "devbox",    label: "DevBox", status: "online" }
};

// The full roster. status ∈ working|idle|queued|waiting|offline (AGENT_STATUSES).
const AGENTS = {
  "ag-driver":    { display_name: "Buzz driver",     kind: "orchestrator", glyph: "Bz", color: "#e9a23b", status: "working" },
  "ag-deepseek":  { display_name: "DeepSeek coder",  kind: "coder",        glyph: "Ds", color: "#5b7fd6", status: "working" },
  "ag-picoder":   { display_name: "Pi coder",        kind: "coder",        glyph: "π",  color: "#8b8fd6", status: "idle"    },
  "ag-architect": { display_name: "Architect iOS",   kind: "reviewer",     glyph: "Ai", color: "#b07fd6", status: "queued"  },
  "ag-kimi":      { display_name: "Kimi reviewer",   kind: "reviewer",     glyph: "Ki", color: "#d65b8f", status: "working" },
  "ag-qa":        { display_name: "iOS QA",          kind: "verifier",     glyph: "Qa", color: "#4fa8a0", status: "idle"    },
  "ag-proof":     { display_name: "Proof runner",    kind: "verifier",     glyph: "Pr", color: "#7aa36a", status: "waiting" },
  "ag-scout":     { display_name: "PR Review Scout", kind: "triage",       glyph: "Sc", color: "#d68f5b", status: "working" },
  "ag-research":  { display_name: "Research Scout",  kind: "research",     glyph: "Rs", color: "#9b8fb8", status: "offline" },
  "ag-ronnie":    { display_name: "Ronnie",          kind: "human",        glyph: "R",  color: "#8b8b93", status: "waiting" }
};

// trail colors are per-item; .2 opacity once done/archived.
const WORK_ITEMS = [
  {
    id: "work_mobile_guard", key: "AGENTIC-575", title: "Mobile API Impact Guard",
    kind: "feature", lifecycle: "active", trail_color: "#5b7fd6",
    machine_id: "rocketbot", floor: "local", pane: "w1G:t1", updated_label: "now",
    setup_state: "ready", needs_attention: false, attention_reason: null,
    current_stage_key: "implement",
    channel: { name: "#agentic-575-guard", external_id: "c-guard" },
    jira: { issue_key: "AGENTIC-575", issue_type: "Story", priority: "P2", url: "https://doximity.atlassian.net/browse/AGENTIC-575" },
    next_action: "Coder lands a scoped diff, then the driver tags Architect iOS.",
    continuity: ["state.json", "handoff.md", "context-dump.md", "coder-brief.md"],
    handoff_cmd: "herdr pi handoff --pane w1G:t1",
    unscoped_threads: [{ id: "bz-2226", title: "Scope note · gateway only, no client SDK", status: "archived", url: "buzz://message?channel=c-guard&id=m-2226" }],
    stages: {
      "start-ticket": { state: "complete", started: "12:02", completed: "12:05",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2231", title: "Kickoff · scope confirmed", status: "archived", url: "buzz://message?channel=c-guard&id=m-2231" }] },
      "plan": { state: "complete", checkpoint_state: "approved", started: "12:05", completed: "12:27",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" },
                 { id: "ag-picoder", link_role: "planner", link_state: "done" }],
        buzz_threads: [{ id: "bz-2233", title: "Plan review · approved by Ronnie", status: "archived", url: "buzz://message?channel=c-guard&id=m-2233" }],
        pi_sessions: [{ id: "pi-8f31", title: "Plan drafting", provider: "pi", model: "opus", status: "ended", machine_id: "rocketbot", pane_id: "w1G:t2", tokens: "212k" }] },
      "implement": { state: "active", started: "12:27",
        agents: [{ id: "ag-deepseek", link_role: "coder", link_state: "active" },
                 { id: "ag-driver",  link_role: "driver", link_state: "active" }],
        buzz_threads: [{ id: "bz-2240", title: "Implement · diff streaming", status: "active", url: "buzz://message?channel=c-guard&id=m-2240" }],
        pi_sessions: [{ id: "pi-9a02", title: "Coder session · schema integration", provider: "pi", model: "deepseek-v3", status: "running", machine_id: "rocketbot", pane_id: "w1G:t1", tokens: "486k" }],
        activity: [
          { t: "13:30", actor: "ag-driver",   message: "Accepted ownership and started execution." },
          { t: "13:31", actor: "ag-picoder",  message: "Reading schema integration points." },
          { t: "13:38", actor: "ag-deepseek", message: "Wrote ImpactGuard middleware · 6 files touched." },
          { t: "13:44", actor: "ag-deepseek", message: "Running scoped tests on api-gateway target." }
        ] },
      "architect-code-review": { state: "ready",
        agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "queued" }] },
      "proof": { state: "pending" }, "code-review-pre-pr": { state: "pending" },
      "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_ask_audit", key: "IOSDOX-27458", title: "Ask Analytics Audit",
    kind: "feature", lifecycle: "active", trail_color: "#e08bb8",
    machine_id: "devbox", floor: "DevBox", pane: "wX:t1", updated_label: "21m",
    setup_state: "ready", needs_attention: true,
    attention_reason: "Checkpoint pending at Proof — approve the analytics event map.",
    current_stage_key: "proof",
    channel: { name: "#iosdox-ask-audit", external_id: "c-audit" },
    jira: { issue_key: "IOSDOX-27458", issue_type: "Story", priority: "P1", url: "https://doximity.atlassian.net/browse/IOSDOX-27458" },
    next_action: "Approve the event map so Pre-PR can start.",
    continuity: ["state.json", "handoff.md", "event-map.md"],
    handoff_cmd: "herdr pi handoff --pane wX:t1 --machine devbox",
    gate_action: { label: "Review event map", kind: "approve", to_stage_key: "code-review-pre-pr" },
    stages: {
      "start-ticket": { state: "complete", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "plan": { state: "complete", checkpoint_state: "approved",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2198", title: "Audit scope", status: "archived", url: "buzz://message?channel=c-audit&id=m-2198" }] },
      "implement": { state: "complete",
        agents: [{ id: "ag-picoder", link_role: "coder", link_state: "done" }],
        pi_sessions: [{ id: "pi-7c11", title: "Audit implementation", provider: "pi", model: "opus", status: "ended", machine_id: "devbox", pane_id: "wX:t1", tokens: "603k" }],
        buzz_threads: [{ id: "bz-2204", title: "Implement thread", status: "archived", url: "buzz://message?channel=c-audit&id=m-2204" }] },
      "architect-code-review": { state: "complete",
        agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "done" }],
        buzz_threads: [{ id: "bz-2210", title: "Review notes · 2 fixes applied", status: "archived", url: "buzz://message?channel=c-audit&id=m-2210" }] },
      "proof": { state: "active", attention: "human", checkpoint_state: "pending", started: "13:23",
        agents: [{ id: "ag-proof", link_role: "verifier", link_state: "active" },
                 { id: "ag-ronnie", link_role: "checkpoint", link_state: "waiting" }],
        buzz_threads: [{ id: "bz-2216", title: "Proof run · event map ready for you", status: "active", url: "buzz://message?channel=c-audit&id=m-2216" }],
        activity: [{ t: "13:23", actor: "ag-proof", message: "Event map assembled — 41 events, 3 new." }] },
      "code-review-pre-pr": { state: "pending" }, "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_moa_mgmt", key: "AGENTIC-472", title: "OpenCode MOA Agent Management",
    kind: "feature", lifecycle: "active", trail_color: "#7aa36a",
    machine_id: "rocketbot", floor: "local", pane: "wK:t9", updated_label: "36m",
    setup_state: "ready", needs_attention: true,
    attention_reason: "PR approved by agents — merge decision is yours.",
    current_stage_key: "pr-triage",
    channel: { name: "#agentic-moa", external_id: "c-moa" },
    jira: { issue_key: "AGENTIC-472", issue_type: "Task", priority: "P2", url: "https://doximity.atlassian.net/browse/AGENTIC-472" },
    pr: { number: 510, url: "https://github.com/doximity/agentic-dev/pull/510" },
    next_action: "Merge or request changes on PR #510.",
    continuity: ["state.json", "pr-summary.md"],
    handoff_cmd: "herdr pi handoff --pane wK:t9",
    gate_action: { label: "Merge PR #510", kind: "complete", to_stage_key: null },
    stages: {
      "start-ticket": { state: "complete" },
      "plan": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "implement": { state: "complete",
        agents: [{ id: "ag-deepseek", link_role: "coder", link_state: "done" }],
        pi_sessions: [{ id: "pi-5510", title: "MOA management build", provider: "pi", model: "deepseek-v3", status: "ended", machine_id: "rocketbot", pane_id: "wK:t9", tokens: "1.2M" }] },
      "architect-code-review": { state: "complete", agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "done" }] },
      "proof": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-proof", link_role: "verifier", link_state: "done" }] },
      "code-review-pre-pr": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "pr": { state: "complete", checkpoint_state: "approved",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2172", title: "PR #510 · review passed", status: "archived", url: "buzz://message?channel=c-moa&id=m-2172" }] },
      "pr-triage": { state: "active", attention: "human", started: "13:08",
        agents: [{ id: "ag-scout", link_role: "triage", link_state: "active" },
                 { id: "ag-ronnie", link_role: "decision", link_state: "waiting" }],
        buzz_threads: [{ id: "bz-2229", title: "Merge decision", status: "active", url: "buzz://message?channel=c-moa&id=m-2229" }] }
    }
  },
  {
    id: "work_mcp_runtime", key: "AGENTIC-512", title: "Managed MCP Runtime",
    kind: "feature", lifecycle: "blocked", trail_color: "#c7a24f",
    machine_id: "rocketbot", floor: "local", pane: "w2A:t4", updated_label: "54m",
    setup_state: "ready", needs_attention: true,
    attention_reason: "Plan changes requested — scope note needs a revision before work starts.",
    current_stage_key: "plan",
    channel: { name: "#agentic-mcp-runtime", external_id: "c-mcp" },
    jira: { issue_key: "AGENTIC-512", issue_type: "Story", priority: "P2", url: "https://doximity.atlassian.net/browse/AGENTIC-512" },
    next_action: "Driver revises the plan scope note, then re-requests your approval.",
    continuity: ["state.json", "plan.md"],
    handoff_cmd: "herdr pi handoff --pane w2A:t4",
    gate_action: { label: "Reopen plan review", kind: "toast", to_stage_key: null },
    stages: {
      "start-ticket": { state: "complete", agents: [{ id: "ag-research", link_role: "research", link_state: "done" }],
        buzz_threads: [{ id: "bz-2183", title: "Runtime survey · 3 candidates", status: "archived", url: "buzz://message?channel=c-mcp&id=m-2183" }] },
      "plan": { state: "blocked", attention: "human", checkpoint_state: "changes_requested", started: "12:48",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "active" },
                 { id: "ag-ronnie", link_role: "checkpoint", link_state: "waiting" }],
        buzz_threads: [{ id: "bz-2221", title: "Plan v2 · you asked to drop the sandbox scope", status: "active", url: "buzz://message?channel=c-mcp&id=m-2221" }],
        activity: [{ t: "12:52", actor: "ag-ronnie", message: "Requested changes — sandbox scope is a separate ticket." }] },
      "implement": { state: "pending" }, "architect-code-review": { state: "pending" },
      "proof": { state: "pending" }, "code-review-pre-pr": { state: "pending" },
      "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_hud_polish", key: "HUD-441", title: "HUD Act-Mode Polish",
    kind: "task", lifecycle: "active", trail_color: "#d65b8f",
    machine_id: "devbox", floor: "DevBox", pane: "wA:t3", updated_label: "4m",
    setup_state: "ready", needs_attention: false,
    current_stage_key: "architect-code-review",
    channel: { name: "#hud-polish", external_id: "c-hud" },
    jira: { issue_key: "HUD-441", issue_type: "Task", priority: "P3", url: "https://doximity.atlassian.net/browse/HUD-441" },
    next_action: "Kimi finishes the review pass, then straight to Proof.",
    continuity: ["state.json", "handoff.md"],
    handoff_cmd: "herdr pi handoff --pane wA:t3 --machine devbox",
    stages: {
      "start-ticket": { state: "complete" },
      "plan": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "implement": { state: "complete", started: "11:02", completed: "12:58",
        agents: [{ id: "ag-deepseek", link_role: "coder", link_state: "done" }],
        pi_sessions: [{ id: "pi-3e77", title: "HUD polish build", provider: "pi", model: "deepseek-v3", status: "ended", machine_id: "devbox", pane_id: "wA:t3", tokens: "348k" }],
        buzz_threads: [{ id: "bz-2237", title: "Panel focus + hotkey fixes", status: "archived", url: "buzz://message?channel=c-hud&id=m-2237" }] },
      "architect-code-review": { state: "active", started: "13:21",
        agents: [{ id: "ag-kimi", link_role: "reviewer", link_state: "active" }],
        pi_sessions: [{ id: "pi-4b19", title: "Review pass · NSPanel focus", provider: "pi", model: "kimi-k2", status: "running", machine_id: "devbox", pane_id: "wA:t5", tokens: "97k" }],
        buzz_threads: [{ id: "bz-2243", title: "Review thread · 1 nit so far", status: "active", url: "buzz://message?channel=c-hud&id=m-2243" }],
        activity: [{ t: "13:36", actor: "ag-kimi", message: "Flagged retain cycle risk in panel controller — checking." }] },
      "proof": { state: "pending" }, "code-review-pre-pr": { state: "pending" },
      "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_drawer_calc", key: "IOSDOX-27102", title: "Drawer Calculator Access",
    kind: "feature", lifecycle: "done", trail_color: "#6a7a8f",
    machine_id: "devbox", floor: "DevBox", pane: null, updated_label: "3h",
    setup_state: "ready", needs_attention: false,
    current_stage_key: null, done_label: "merged this morning · monitoring",
    channel: { name: "#iosdox-drawer-calc", external_id: "c-calc" },
    jira: { issue_key: "IOSDOX-27102", issue_type: "Story", priority: "P2", url: "https://doximity.atlassian.net/browse/IOSDOX-27102" },
    pr: { number: 11856, url: "https://github.com/doximity/iOS-Doximity/pull/11856" },
    continuity: ["state.json", "pr-summary.md"],
    stages: {
      "start-ticket": { state: "complete" }, "plan": { state: "complete", checkpoint_state: "approved" },
      "implement": { state: "complete", agents: [{ id: "ag-picoder", link_role: "coder", link_state: "done" }] },
      "architect-code-review": { state: "complete", agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "done" }] },
      "proof": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-qa", link_role: "verifier", link_state: "done" }] },
      "code-review-pre-pr": { state: "complete", checkpoint_state: "approved" },
      "pr": { state: "complete", checkpoint_state: "approved" },
      "pr-triage": { state: "complete", completed: "10:41", agents: [{ id: "ag-scout", link_role: "triage", link_state: "done" }] }
    }
  }
];

// Pre-pipeline intake: ideas + tickets mid-setup (setup_state machine:
// board_created → channel_linked → ready).
const INTAKE = [
  {
    id: "work_review_memory", key: "IDEA-07", title: "Project Review Memory",
    kind: "idea", setup_state: "board_created", updated_label: "forming",
    note: "Explore first. No worktree until a prototype decision is approved.",
    cast: ["ag-driver"], next_setup: "Link a Buzz channel"
  },
  {
    id: "work_ask_deflection", key: "IOSDOX-27655", title: "Ask Deflection Metrics",
    kind: "feature", setup_state: "channel_linked", updated_label: "12m",
    channel: { name: "#ask-deflection", external_id: "c-defl" },
    jira: { issue_key: "IOSDOX-27655", issue_type: "Story", priority: "P2" },
    note: "Channel linked. No driver attached yet — attach one to start the line.",
    next_setup: "Attach driver"
  }
];

// Jira candidates rail (from GET /api/v1/active-work jira_candidates).
const JIRA_CANDIDATES = [
  { issue_key: "IOSDOX-27710", title: "Colleague Connect prompts", issue_type: "Story", priority: "P3", status: "To Do" },
  { issue_key: "AGENTIC-529",  title: "OpenCode replay harness",   issue_type: "Task",  priority: "P2", status: "To Do" }
];
