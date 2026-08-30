// Canonical sample dataset for the three Active Work prototypes.
// Field names mirror the real harness projection (herdr_harness/active_work_store.py)
// so a future wiring to GET /api/v1/active-work is mechanical.
// All three options inline this same data for apples-to-apples comparison.

const PIPELINE = {
  id: "pipeline_buzz_feature_work_v1",
  slug: "buzz-feature-work",
  title: "Buzz feature work",
  stages: [
    { stage_key: "start-ticket",           sequence: 1, phase_key: "open",  title: "Start",        skill_name: "buzz-start-ticket",          checkpoint_kind: "none"  },
    { stage_key: "plan",                   sequence: 2, phase_key: "open",  title: "Plan",         skill_name: "buzz-plan",                  checkpoint_kind: "human" },
    { stage_key: "implement",              sequence: 3, phase_key: "build", title: "Implement",    skill_name: "buzz-implement",             checkpoint_kind: "none"  },
    { stage_key: "architect-code-review",  sequence: 4, phase_key: "build", title: "Agent review", skill_name: "buzz-architect-code-review", checkpoint_kind: "none"  },
    { stage_key: "proof",                  sequence: 5, phase_key: "prove", title: "Proof",        skill_name: "buzz-proof",                 checkpoint_kind: "human" },
    { stage_key: "code-review-pre-pr",     sequence: 6, phase_key: "prove", title: "Pre-PR",       skill_name: "buzz-code-review-pre-pr",    checkpoint_kind: "human" },
    { stage_key: "pr",                     sequence: 7, phase_key: "ship",  title: "PR",           skill_name: "buzz-pr",                    checkpoint_kind: "human" },
    { stage_key: "pr-triage",              sequence: 8, phase_key: "ship",  title: "Triage",       skill_name: "buzz-pr-triage",             checkpoint_kind: "none"  }
  ]
};

// avatar_key maps to the SVG symbol set; hue used for gradient tints.
const AGENTS = {
  "ag-driver":    { display_name: "Buzz driver",     kind: "orchestrator", avatar_key: "driver",    status: "working" },
  "ag-deepseek":  { display_name: "DeepSeek coder",  kind: "coder",        avatar_key: "coder",     status: "working" },
  "ag-picoder":   { display_name: "Pi coder",        kind: "coder",        avatar_key: "coder",     status: "working" },
  "ag-architect": { display_name: "Architect iOS",   kind: "reviewer",     avatar_key: "architect", status: "queued"  },
  "ag-proof":     { display_name: "Proof runner",    kind: "verifier",     avatar_key: "qa",        status: "working" },
  "ag-scout":     { display_name: "PR Review Scout", kind: "triage",       avatar_key: "scout",     status: "working" },
  "ag-ronnie":    { display_name: "Ronnie",          kind: "human",        avatar_key: "human",     status: "waiting" }
};

const WORK_ITEMS = [
  {
    id: "work_mobile_guard", key: "AGENTIC-575", title: "Mobile API Impact Guard",
    kind: "feature", kind_label: "Jira ticket",
    lifecycle: "active", needs_attention: false, attention_reason: null,
    current_stage_key: "implement", floor: "local", pane: "w1G:t1", updated_label: "now",
    progress: { completed: 2, total: 8 },
    next_action: "Coder produces a scoped diff, then the Buzz driver adds and tags Architect iOS.",
    continuity: ["state.json", "handoff.md", "context-dump.md", "coder brief"],
    stages: {
      "start-ticket": { state: "complete", started: "12:02", completed: "12:05",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2231", title: "Kickoff · scope confirmed", status: "archived", url: "buzz://message?channel=c-guard&id=m-2231" }],
        pi_sessions: [] },
      "plan": { state: "complete", checkpoint_state: "approved", started: "12:05", completed: "12:27",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" },
                 { id: "ag-picoder", link_role: "planner", link_state: "done" }],
        buzz_threads: [{ id: "bz-2233", title: "Plan review · approved by Ronnie", status: "archived", url: "buzz://message?channel=c-guard&id=m-2233" }],
        pi_sessions: [{ id: "pi-8f31", title: "Plan drafting", provider: "pi", model: "opus", status: "ended", pane_id: "w1G:t2", tokens: "212k" }] },
      "implement": { state: "active", attention: "none", started: "12:27",
        agents: [{ id: "ag-deepseek", link_role: "coder", link_state: "active" },
                 { id: "ag-driver",  link_role: "driver", link_state: "active" }],
        buzz_threads: [{ id: "bz-2240", title: "Implement · diff streaming", status: "active", url: "buzz://message?channel=c-guard&id=m-2240" }],
        pi_sessions: [{ id: "pi-9a02", title: "Coder session · schema integration", provider: "pi", model: "deepseek-v3", status: "running", pane_id: "w1G:t1", tokens: "486k" }],
        activity: [
          { t: "13:30", actor: "ag-driver",   message: "Accepted ownership and started execution." },
          { t: "13:31", actor: "ag-picoder",  message: "Reading schema integration points." },
          { t: "13:38", actor: "ag-deepseek", message: "Wrote ImpactGuard middleware · 6 files touched." },
          { t: "13:44", actor: "ag-deepseek", message: "Running scoped tests on api-gateway target." }
        ] },
      "architect-code-review": { state: "ready",
        agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "queued" }],
        buzz_threads: [], pi_sessions: [] },
      "proof": { state: "pending" }, "code-review-pre-pr": { state: "pending" },
      "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_ask_audit", key: "IOSDOX-27458", title: "Ask Analytics Audit",
    kind: "feature", kind_label: "Feature",
    lifecycle: "active", needs_attention: true,
    attention_reason: "Checkpoint pending at Proof — approve the analytics event map.",
    current_stage_key: "proof", floor: "DevBox", pane: "wX:t1", updated_label: "21m",
    progress: { completed: 4, total: 8 },
    next_action: "Approve the event map so Pre-PR can start.",
    continuity: ["state.json", "handoff.md", "event-map.md"],
    stages: {
      "start-ticket": { state: "complete", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "plan": { state: "complete", checkpoint_state: "approved",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2198", title: "Audit scope", status: "archived", url: "buzz://message?channel=c-audit&id=m-2198" }] },
      "implement": { state: "complete",
        agents: [{ id: "ag-picoder", link_role: "coder", link_state: "done" }],
        pi_sessions: [{ id: "pi-7c11", title: "Audit implementation", provider: "pi", model: "opus", status: "ended", pane_id: "wX:t1", tokens: "603k" }],
        buzz_threads: [{ id: "bz-2204", title: "Implement thread", status: "archived", url: "buzz://message?channel=c-audit&id=m-2204" }] },
      "architect-code-review": { state: "complete",
        agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "done" }],
        buzz_threads: [{ id: "bz-2210", title: "Review notes · 2 fixes applied", status: "archived", url: "buzz://message?channel=c-audit&id=m-2210" }] },
      "proof": { state: "active", attention: "human", checkpoint_state: "pending", started: "13:23",
        agents: [{ id: "ag-proof", link_role: "verifier", link_state: "active" },
                 { id: "ag-ronnie", link_role: "checkpoint", link_state: "waiting" }],
        buzz_threads: [{ id: "bz-2216", title: "Proof run · event map ready for you", status: "active", url: "buzz://message?channel=c-audit&id=m-2216" }],
        pi_sessions: [],
        activity: [{ t: "13:23", actor: "ag-proof", message: "Event map assembled — 41 events, 3 new." }] },
      "code-review-pre-pr": { state: "pending" }, "pr": { state: "pending" }, "pr-triage": { state: "pending" }
    }
  },
  {
    id: "work_moa_mgmt", key: "AGENTIC-472", title: "OpenCode MOA Agent Management",
    kind: "feature", kind_label: "Ticket + PR #510",
    lifecycle: "active", needs_attention: true,
    attention_reason: "PR approved by agents — merge decision is yours.",
    current_stage_key: "pr-triage", floor: "local", pane: "wK:t9", updated_label: "36m",
    progress: { completed: 7, total: 8 },
    next_action: "Merge or request changes on PR #510.",
    continuity: ["state.json", "pr-summary.md"],
    stages: {
      "start-ticket": { state: "complete" },
      "plan": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "implement": { state: "complete",
        agents: [{ id: "ag-deepseek", link_role: "coder", link_state: "done" }],
        pi_sessions: [{ id: "pi-5510", title: "MOA management build", provider: "pi", model: "deepseek-v3", status: "ended", pane_id: "wK:t9", tokens: "1.2M" }] },
      "architect-code-review": { state: "complete", agents: [{ id: "ag-architect", link_role: "reviewer", link_state: "done" }] },
      "proof": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-proof", link_role: "verifier", link_state: "done" }] },
      "code-review-pre-pr": { state: "complete", checkpoint_state: "approved", agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }] },
      "pr": { state: "complete", checkpoint_state: "approved",
        agents: [{ id: "ag-driver", link_role: "driver", link_state: "done" }],
        buzz_threads: [{ id: "bz-2172", title: "PR #510 · review passed", status: "archived", url: "buzz://message?channel=c-moa&id=m-2172" }] },
      "pr-triage": { state: "active", attention: "human", started: "13:08",
        agents: [{ id: "ag-scout", link_role: "triage", link_state: "active" },
                 { id: "ag-ronnie", link_role: "decision", link_state: "waiting" }],
        buzz_threads: [{ id: "bz-2229", title: "Merge decision", status: "active", url: "buzz://message?channel=c-moa&id=m-2229" }],
        pi_sessions: [] }
    }
  },
  {
    id: "work_review_memory", key: "IDEA-07", title: "Project Review Memory",
    kind: "idea", kind_label: "Idea",
    lifecycle: "active", needs_attention: false,
    current_stage_key: null, floor: "no floor yet", pane: null, updated_label: "forming",
    progress: { completed: 0, total: 8 },
    next_action: "Explore first. No worktree until a prototype decision is approved.",
    note: "Idea intake, before the ticket pipeline.",
    stages: {},
    cast_note: "Buzz driver shaping"
  }
];
