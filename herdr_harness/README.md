# Herdr Harness backend

This package is a standard-library HTTP adapter for Herdr 0.8. It talks to the
native newline-delimited JSON Unix socket, caches `session.snapshot`, composes
workspace relationships without dropping unknown Herdr fields, and forwards
native events through Server-Sent Events.

`snapshot.updated` SSE records are intentionally compact. They carry focused
IDs and pane revisions, then clients fetch `/snapshot` or `/workspaces` when
they need the complete native records. This keeps the replay buffer bounded
even for large sessions.

## Run

Create a stable token once so restarting the backend does not invalidate the
credential already stored in the iOS Keychain:

```bash
mkdir -p "$HOME/.config/herdr-harness"
umask 077
openssl rand -hex 32 > "$HOME/.config/herdr-harness/api-token"
chmod 600 "$HOME/.config/herdr-harness/api-token"
```

Reuse it for every launch:

```bash
export HERDR_SESSION=herdr-ios-fixtures
export HERDR_HARNESS_API_TOKEN="$(<"$HOME/.config/herdr-harness/api-token")"
printf 'Herdr pairing token: %s\n' "$HERDR_HARNESS_API_TOKEN"
python3 herdr_dashboard.py --no-browser
```

Do not repeat the generation block unless intentionally rotating the token and
updating the iOS app.

The launcher refuses to start without authentication. An unauthenticated
loopback server is available only through the explicit development override
`--allow-insecure-local`, and that override cannot bind to a shared address.

The server binds to loopback on port `9092` by default. The setup page is at
`/`. Publish the complete REST and SSE surface privately with Tailscale Serve:

```bash
tailscale serve status
tailscale serve --bg --https=8461 9092
tailscale serve status
```

Use 8461 only when the first status command proves that exact port is unused.
If another handler owns it, choose a different unused high port, set
`HERDR_HARNESS_TAILSCALE_HTTPS_PORT` to that port, and substitute it in every
command and URL. The dedicated listener preserves the default HTTPS root but
cannot preserve a handler already on the same port. Remove only the handler you
created with `tailscale serve --https=<chosen-port> off`.

Use the exact HTTPS URL from `tailscale serve status` in the iOS app. SSE
topology and terminal-frame streams use the same origin. The raw Herdr Unix
socket is never shared. For an explicitly trusted LAN, opt in with
`HERDR_HARNESS_HOST=0.0.0.0`; bearer authentication is still mandatory through
the launcher, and the iOS app still requires HTTPS for non-loopback hosts.
To publish the verified address through `/api/v1/network`, start or restart
the backend with `HERDR_HARNESS_TAILSCALE_URL` set to that exact HTTPS URL.

Configuration:

- `HERDR_SOCKET_PATH`: explicit Herdr API socket.
- `HERDR_SESSION`: `default` or a named Herdr session.
- `HERDR_HARNESS_API_TOKEN`: bearer token required by the launcher and every
  API route. It is optional only with the explicit loopback-only
  `--allow-insecure-local` development override.
- `HERDR_HARNESS_PORT` and `HERDR_HARNESS_HOST`: listener overrides. The host
  defaults to `127.0.0.1`.
- `HERDR_HARNESS_TAILSCALE_URL`: exact verified Serve URL advertised by
  `/network`, including port or path. Tailscale identity alone is never
  reported as a working endpoint.
- `HERDR_HARNESS_TAILSCALE_HTTPS_PORT`: suggested isolated Serve port, default
  `8461`.
- `HERDR_HARNESS_CMUX_URL`: trusted upstream cmux harness API used for Git,
  Skills, Files, Jira, attachments, and private voice transcription. It defaults to
  `http://127.0.0.1:9091`; a trailing `/harness` is accepted and normalized.
- `HERDR_CLIENT_SOCKET_PATH`: optional raw terminal client socket override used
  by `herdr terminal session observe`.
- `HERDR_APNS_KEY_ID`, `HERDR_APNS_TEAM_ID`, and `HERDR_APNS_KEY_PATH`: optional
  APNs token credentials.
- `HERDR_APNS_TOPIC`: default iOS bundle identifier, unless supplied during
  device registration.
- `HERDR_APNS_ENV`: `sandbox` (default) or `production`.
- `HERDR_HARNESS_PUSH_STORE_PATH`: optional persisted-device file override.
- `HERDR_HARNESS_ALERT_STORE_PATH`: persisted alert journal. The launcher
  defaults to `~/.config/herdr-harness/alerts.json` with mode `0600`.
- `HERDR_HARNESS_ACTIVE_WORK_STORE_PATH`: Herdr-owned SQLite source of truth
  for Active Work. The launcher defaults to
  `~/.config/herdr-harness/active-work.sqlite3`; WAL files and the database are
  restricted to the current user.
- `HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN` or
  `HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN_FILE`: optional least-privilege
  credential for the `herdr-active-work` CLI. It authorizes every
  `/api/v1/active-work` route, including observation ingestion, but no terminal,
  pane, workspace, alert, push, or other Herdr route. The conventional private
  file is `~/.config/herdr-harness/active-work-manage-token`, which the server
  discovers from `HOME` when it exists. Choose the value or file form, never
  both. The main API token remains valid for Active Work so existing Mac and
  iOS clients remain compatible. Main, manage, and ingest credentials must be
  distinct when configured together.
- `HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN`: optional least-privilege bearer
  token accepted only by Active Work sync-target and ingestion routes. The
  main API token remains valid for those routes as well.
- `HERDR_HARNESS_TERMINAL_MAX_STREAMS`: concurrent terminal observer limit,
  default `16`.
- `HERDR_HARNESS_TERMINAL_MAX_SECONDS`: renewal lifetime for each observer,
  default `3600`.
- `HERDR_RESPONSE_AUDIO_TTS_URL`: optional TTS base URL or full
  `/v1/audio/speech` URL. When absent, the backend reads `ttsUrl` from the
  private `~/.config/herdr-harness/response-audio.json` file. Keep that file
  outside source control with mode `0600`; an absent, malformed, unreadable,
  or non-regular file leaves response audio unavailable without preventing
  startup.

For any Tailscale-shared server, set `HERDR_HARNESS_API_TOKEN` to a long random
value and configure the same value in the iOS app.

APNs background delivery requires a signed physical device, a provisioning
profile with Push Notifications, and an Apple `.p8` key whose team and topic
match the signed app. Debug device registrations use `sandbox`; Release uses
`production`. Simulator and in-app local notification tests do not prove APNs
delivery. See the root `HERDR_HARNESS.md` runbook for full device setup and
troubleshooting.

## Core API

- `GET /api/v1/health`
- `GET /api/v1/network`
- `GET /api/v1/snapshot`
- `GET /api/v1/workspaces`
- `GET /api/v1/workspaces/{id}`
- `GET /api/v1/panes/{id}/output`
- `GET /api/v1/panes/{id}/stream?cols=100&rows=32`
- Workspace-scoped Git status, diff, stage, unstage, Skills, file search, and
  attachment routes. These retain the Herdr API schema while delegating to the
  existing cmux API by the server-resolved checkout path. For attachments,
  Herdr resolves the matching live cmux workspace UUID and index first. cmux
  owns attachment storage, retention, and dashboard-startup cleanup.
- `GET /api/v1/jira/assigned` and `GET /api/v1/jira/issue`, delegated to the
  existing cmux Jira integration.
- `GET /api/v1/active-work` returns the durable board and live Jira setup
  candidates. Jira candidates are never imported by observation. A user must
  explicitly call `POST /api/v1/active-work/jira/{key}/setup`.
- `POST /api/v1/active-work/items`, `GET|PATCH
  /api/v1/active-work/items/{id}`, and `POST
  /api/v1/active-work/items/{id}/transitions` manage Feature, Task, and Idea
  records with optimistic revisions and the versioned Buzz pipeline.
- `GET /api/v1/active-work/workflows` lists stored workflow templates. `GET
  /api/v1/active-work/workflows/{slug}` returns the latest version, or accepts
  optional `?version=` for a specific version. `POST
  /api/v1/active-work/workflows` applies a workflow idempotently: identical
  content is a no-op, while different content at the same slug and version is
  a `409` that asks the caller to bump the version.
- `PATCH /api/v1/active-work/items/{id}/stages/{stageKey}` deep-merges
  `{summary?, content?}` directly into one stage without an ingestion envelope.
  It returns `404` when the stage is not on that item's workflow template.
  The board projection's existing `pipeline` key is unchanged and now also
  includes `pipelines`, every applied workflow that is the default or in use.
- `GET /api/v1/active-work/sync-targets` and `POST
  /api/v1/active-work/ingestions` support an external Buzz reconciler. Sync is
  merge-only, idempotent, stale-safe, and cannot create an untracked Jira
  item. Herdr stores identifiers, bounded summaries, and links, never Buzz or
  Pi transcript bodies.
- `POST /api/v1/voice/transcriptions` accepts bounded 16 kHz mono PCM16 WAV
  recordings. The bearer-authenticated Herdr server proxies them to cmux,
  which uses Parakeet and its existing faster-whisper fallback. The response
  contains text for the iOS composer and never submits a prompt or appends to
  cmux chat.
- `GET /api/v1/events`. The Active Work manage token is also accepted here and
  can observe event metadata (IDs and revisions only, never content).
- `GET /board/` serves the read-only Active Work board page before auth, like
  `/herdr-web/`. `GET /board` redirects relatively to `board/`; the page's own
  data calls still require a token.
- `GET /api/v1/alerts`, `POST /api/v1/alerts/{id}/read`
- `GET /api/v1/push/status`, `POST /api/v1/push/devices`, and
  `POST /api/v1/push/unregister`
- `POST /api/v1/live-activities` and
  `POST /api/v1/live-activities/unregister` register ActivityKit push tokens
  for Herd Pulse background updates.
- Workspace create, rename, focus, and close routes.
- Tab create, rename, focus, and close routes.
- Pane split, rename, focus, close, text, key, and atomic command routes.
- `POST /api/v1/panes/{id}/prompt` uses Herdr's agent-aware prompt API.
- `POST /api/v1/panes/{id}/start-agent` starts a supported agent in an
  existing shell pane.

Mutation results retain Herdr's native `result` object. The snapshot route
returns the raw `SessionSnapshot`. Workspace records add only `tabs`, `panes`,
`agents`, and `layouts`, each containing native Herdr records.

### Workflows

A workflow config contains phases and ordered stages. Each stage declares its
skill, checkpoint, and forward-only `next` stages. Shipped defaults live in
`herdr_harness/workflows/*.json`: `buzz-feature-work` expresses the existing
default pipeline in this schema, and `research-spike` is a second example.

At startup, the server loads shipped configs first, then
`$HOME/.config/herdr-harness/workflows/*.json` or
`HERDR_HARNESS_WORKFLOWS_DIR`. It skips and logs a warning for each file that
fails validation, without failing startup. `create --workflow SLUG` in the CLI,
or `"workflow": "<slug>"` in `POST /api/v1/active-work/items`, starts an item
at that workflow's first stage. Later transitions validate against that
workflow's own stages.

Stage documents live in `content.documents`, keyed by document ID. Each entry
uses `title`, `kind`, `skill`, `status` (`approved`, `changes_requested`,
`awaiting-you`, or `info`), `by`, `at`, and optional `url`:

```json
"content": { "documents": { "plan-approval": {
  "title": "plan-approval.html", "kind": "html", "skill": "buzz-plan",
  "status": "approved", "by": "Ronnie", "at": "2026-08-30T18:04:00.000Z",
  "url": "https://.../tickets/AGENTIC-575/plan-approval.html"
}}}
```

`herdr-active-work attach-doc` builds this payload.

### Active Work command line

`herdr-active-work` is the supported interface for people and agents that need
to read or manage the board. It is a thin client for the authenticated Herdr
API, not a direct SQLite or `acli` wrapper. By default it connects to
`http://127.0.0.1:9092`, reads the manage credential from
`~/.config/herdr-harness/active-work-manage-token`, and identifies writes as
`agent:herdr-active-work-cli`.

Every successful command writes one compact JSON envelope to stdout. Every
failure writes one JSON error envelope to stderr and exits nonzero. The stable
envelope version is `herdr.active-work.cli/v1` and contains `ok`, `command`,
and either `data` or `error`. `--pretty` indents the same JSON for manual use;
there is no `--json` flag because JSON is always the output format. Global
options must precede the command:

```bash
herdr-active-work --pretty candidates
herdr-active-work --timeout 30 list | jq .
```

The command surface is:

| Command | Purpose |
| --- | --- |
| `candidates [--all]` | List untracked assigned Jira candidates. By default, candidates already represented on the board are omitted. |
| `list [--full]` | List tracked work in a compact agent-friendly shape, or return full projections with `--full`. |
| `show REF` | Resolve a work item ID or Jira key and return its full projection. |
| `connect JIRA-KEY` | Explicitly connect exactly one Jira issue. The operation is idempotent and refreshes the same item when repeated. |
| `create --title T ...` | Create a non-Jira Feature, Task, or Idea. |
| `update REF ...` | Patch mutable item fields, optionally guarded by `--expected-revision N`. |
| `move REF --to STAGE ...` | Move an item through its versioned pipeline, with optional state, attention, checkpoint, note, and revision controls. |
| `observe --file PATH` | Submit one exact Active Work ingestion object from a file, or use `--file -` for stdin. |
| `workflow-list` | List stored workflow templates. |
| `workflow-show SLUG [--wf-version N]` | Show a workflow's phases, stages, and allowed next stages. |
| `workflow-apply --file PATH|- [--validate]` | Validate and apply a workflow config, or validate locally only. |
| `stage-set REF --stage KEY [--summary TEXT] [--content-file PATH|-]` | Merge a summary or JSON content object into one stage. |
| `attach-doc REF --stage KEY --id DOCID --title T --kind html\|json\|md\|other --skill NAME --status approved\|changes_requested\|awaiting-you\|info [--by NAME] [--url URL] [--at ISO]` | Attach or update one stage document. |

The full authoring and state-management guide — workflow config schema, the
writable state vocabulary, gate/attention recipes, the stage-document
convention, and the direct API table — lives in `docs/WORKFLOWS.md`.

Listing candidates never creates board records. `connect` deliberately accepts
one Jira key and has no bulk or `--all` form, so importing assigned work always
requires a singular, reviewable decision:

```bash
herdr-active-work candidates | jq .
herdr-active-work --pretty connect AGENTIC-575
herdr-active-work show AGENTIC-575 | jq '.data'
```

Create, update, and pipeline movement expose the same validated fields as the
HTTP API:

```bash
herdr-active-work create \
  --kind task \
  --title "Prepare Active Work rollout" \
  --summary "Verify the agent and manual workflows" \
  --next-action "Run the Work Mac smoke test"

herdr-active-work update AGENTIC-575 \
  --next-action "Review the implementation" \
  --expected-revision 3

herdr-active-work move AGENTIC-575 \
  --to implement \
  --state active \
  --attention none \
  --checkpoint none \
  --note "Implementation started" \
  --expected-revision 4
```

`create` also accepts `--id`, `--lifecycle`, `--current-stage`, `--workflow`,
and `--metadata-json`. `update` accepts the mutable title, summary, lifecycle,
kind, next-action, and metadata fields. Valid values are printed by
`herdr-active-work <command> --help`; callers should use revision guards when
acting on state fetched earlier.

`observe` is the low-level agent and integration bridge to
`POST /api/v1/active-work/ingestions`. Its file must contain one JSON object
with at least `source`, `idempotency_key`, `observed_at`, and `selector`. The
remaining item, stage, channel, thread, and activity fields are optional
observations to merge. It is not a watch command and never creates or connects
a work item. Reusing an idempotency key with the same payload is a replay;
older observations are accepted as stale without moving durable state
backward.

For example, `observation.json` can carry a caller's bounded next-action
observation for an already-connected Jira issue:

```json
{
  "source": "agent",
  "idempotency_key": "agent:AGENTIC-575:20260826T224500Z",
  "observed_at": "2026-08-26T22:45:00Z",
  "selector": { "jira_key": "AGENTIC-575" },
  "item": { "next_action": "Review the implementation result." }
}
```

```bash
herdr-active-work observe --file observation.json
jq -c . observation.json | herdr-active-work observe --file -
```

Configure the CLI with global options or their environment equivalents:

- `--base-url` or `HERDR_ACTIVE_WORK_BASE_URL`
- `--token-file` or `HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE`
- `HERDR_ACTIVE_WORK_MANAGE_TOKEN` for an ephemeral direct value
- `--actor` or `HERDR_ACTIVE_WORK_ACTOR`, in `agent:<lowercase-slug>` form
- `--timeout` or `HERDR_ACTIVE_WORK_TIMEOUT`

Do not set both manage-token environment forms. Prefer the mode-`0600` token
file because a direct value can leak through shell or process configuration;
the CLI intentionally has no raw-token command-line option. The file must be a
regular file owned by the current user, must not be a symlink, and must have no
group or world permissions. The manage token can use every Active Work route,
including `observe`, but cannot control any other Herdr resource. The separate
ingest token is narrower still: it accepts only sync-target reads and Buzz
ingestion writes.

### Active Work Buzz reconciliation

Active Work is deliberately available when Buzz or Jira is offline. After a
Jira candidate is connected from the Mac app or CLI, an external process can
reconcile the matching `tickets/<KEY>/state.json`, Buzz channel roster, and
discussion identifiers into Herdr:

```bash
HERDR_ACTIVE_WORK_TOKEN="$HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN" \
  python3 scripts/herdr_active_work_sync.py --dry-run

HERDR_ACTIVE_WORK_TOKEN="$HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN" \
  python3 scripts/herdr_active_work_sync.py --ticket AGENTIC-575
```

For a launchd job, prefer an absolute path to a token file instead of placing
the bearer token in the job environment:

```bash
chmod 600 /Users/ronnierocha/.config/herdr-harness/active-work-ingest-token
HERDR_ACTIVE_WORK_TOKEN_FILE=/Users/ronnierocha/.config/herdr-harness/active-work-ingest-token \
  python3 scripts/herdr_active_work_sync.py
```

`--token-file` is the CLI equivalent. The file must be a small, non-empty
regular file owned by the current user, may not be a symlink, and may not have
group or world permissions. Do not configure `HERDR_ACTIVE_WORK_TOKEN` or
`HERDR_HARNESS_API_TOKEN` at the same time as a token file.

Non-interactive jobs can load the Buzz identity the same way with
`--buzz-private-key-file` or `BUZZ_PRIVATE_KEY_FILE`. Do not also set
`BUZZ_PRIVATE_KEY`. The script validates the private file, then supplies the
key only in the Buzz CLI child process environment. It is never added to the
command arguments or the Herdr ingestion document.

`scripts/com.ronnierocha.herdr-active-work-sync.plist` is the Work Mac launchd
job. It runs once at login and every five minutes with the scoped token file,
the private Buzz identity file, the Work Mac Buzz relay URL, the local Buzz
CLI, and the canonical Buzz workflow checkout. Install it in
`~/Library/LaunchAgents/`, validate it with `plutil -lint`, then use
`launchctl bootstrap gui/$(id -u) ...` and `launchctl kickstart -k ...`.

The script first reads `/api/v1/active-work/sync-targets` and skips every Jira
directory that has not been explicitly set up. It stores Buzz channel,
agent-runtime, Herdr workspace/pane association, and discussion-thread
identifiers plus bounded metadata. A Pi-looking association is a runtime proxy,
not a durable copy of a native ephemeral Pi session ID, and the stock sync does
not synthesize activity events. It does not copy message bodies, prompts,
credentials, or transcripts.

That five-minute job is reconciliation, not orchestration. It refreshes only
already-connected tickets and never connects assigned Jira work, creates a
Buzz channel, transitions Jira, starts an agent, creates a Herdr workspace, or
sends a prompt. `observe` likewise submits one caller-produced snapshot and
does not install or schedule a watcher. Manual and agent-driven `create`,
`update`, and `move` operations remain explicit.

The pane stream route launches Herdr's terminal observer and relays its NDJSON
terminal frames as authenticated SSE. `/output` remains the low-cost text or
ANSI snapshot fallback.

For a Parakeet service on another tailnet machine, configure the cmux process
with `ORCHESTRATOR_V2_PARAKEET_URL`. The iPhone still connects only to the
authenticated Herdr origin. When Parakeet listens on the Lux PC's Tailscale
interface, cmux can use its MagicDNS name directly:

```bash
ORCHESTRATOR_V2_PARAKEET_URL=http://custom-lux-pc:18793
```

If Parakeet remains loopback-only, use an SSH or Tailscale tunnel on the Mac
running cmux instead:

```bash
ORCHESTRATOR_V2_PARAKEET_URL=http://127.0.0.1:18793
```

The remote `/transcribe` service must accept multipart WAV audio and return a
JSON `text` field. Keep the service private to the tailnet or loopback tunnel.
The server limits recordings to 20 MB and rejects redirects, oversized
responses, non-WAV input, and unbounded timeouts.

APNs device registration is protected by the API bearer token and persisted in
a mode-0600 JSON file. Delivery is disabled until all signing credentials and a
topic are available. Agent `blocked` and `done` transitions enqueue delivery on
a background thread, so APNs latency never stalls the native Herdr event loop.
Herd Pulse registrations use the same credentials and the ActivityKit topic
derived from the registered app bundle identifier. Their Lock Screen payload is
limited to aggregate workspace, pane, working, blocked, and ready counts. It
never includes terminal output, paths, labels, titles, or session identifiers.
The implementation invokes the system `openssl` for ES256 token signing and
`curl --http2` for Apple's HTTP/2 endpoint, without third-party Python packages.
Push registration and removal return `503 api_token_required` when the harness
bearer token is not configured, even though the rest of the API may run in its
optional unauthenticated development mode.

### Fleet catalog synchronization

`POST /api/v1/fleet/sync` first verifies the allowlisted Git remote, branch,
upstream, and clean checkout boundary, then fetches and fast-forwards the
catalog. Only after that trusted catalog read does it reconcile persisted
Herdr-managed records for writable skills and Pi extensions. CLI recipes,
unmanaged or external items, symlinked targets, and locally drifted targets
are never changed.

Sync All restores a managed target that is missing on disk when its valid
ownership record remains. An explicit Uninstall removes that record, so a
remaining record is the evidence that makes this restore safe. If the record
is absent, the target is unmanaged and remains untouched.

For an outdated managed item, the observed target digest must still equal the
digest recorded when Herdr last wrote it. The previous copy is atomically moved
to the private quarantine before the catalog copy is installed and verified.
If installation or state persistence fails, the new copy is removed when it is
still provably Herdr's copy and the quarantined version is restored. A failure
for one item does not stop independent items from being reconciled.

The response keeps the existing inventory fields and adds a `reconciliation`
object. Its `counts` (also available as flat aliases) include `attempted`,
`updated`, `current`, `restored`, `skippedDrifted`, `failed`, and
`rollbackRestored`; `items`, `outcomes`, and `results` contain bounded per-item
operation records. Item failures are reported in that object while the
endpoint remains `ok: true`, so the client does not mark a reachable machine
offline.

### Mutation contract

All mutation responses are `{ "ok": true, "result": <native Herdr result> }`
unless noted. Identifiers are URL-encoded path components.

- `POST /workspaces`: `{label?, cwd?, focus?, env?}`
- `PATCH /workspaces/{id}`: `{label}`
- `DELETE /workspaces/{id}` and `POST /workspaces/{id}/focus`: `{}`
- `POST /workspaces/{id}/tabs`: `{label?, cwd?, focus?, env?}`
- `PATCH /tabs/{id}`: `{label}`
- `DELETE /tabs/{id}` and `POST /tabs/{id}/focus`: `{}`
- `PATCH /panes/{id}`: `{label}`; `null` clears the label
- `DELETE /panes/{id}` and `POST /panes/{id}/focus`: `{}`
- `POST /panes/{id}/split`: `{direction, ratio?, cwd?, focus?, env?}`
- `POST /panes/{id}/send-text`: `{text}`
- `POST /panes/{id}/send-keys`: `{keys: ["ctrl+c"]}`
- `POST /panes/{id}/run`: `{command}` for atomic text plus Enter
- `POST /panes/{id}/prompt`: `{text, wait?, until?, timeoutMs?}`
- `POST /panes/{id}/start-agent`: `{name, kind, args?, timeoutMs?}`
- `POST /alerts/{id}/read` and `POST /alerts/read-all`: `{}`
- `POST /push/devices`: `{deviceToken, bundleId, environment}`
- `POST /push/unregister`: `{deviceToken}`. Tokens never appear in URLs.
- `POST /live-activities`: `{activityId, pushToken, bundleId, environment}`
- `POST /live-activities/unregister`: `{activityId, pushToken?}`

Prefix every path above with `/api/v1`. Input lengths, ratios, key names,
statuses, paths, and timeouts are bounded in `server.py`; invalid input returns
an error envelope with HTTP 4xx. `GET /api/v1` returns a machine-readable route
index. SSE sends `stream.reset` when replay continuity cannot be guaranteed.

### Event stream resume

`GET /api/v1/events` without `Last-Event-ID` or an `after` query starts at the
current broker cursor instead of replaying its retained ring. After `ready`, it
sends one synthetic `snapshot.updated` record so a newly connected client
refreshes once. The `ready` payload includes `resumeFrom`, which is the cursor
to retain for a later reconnect. Supplying `after=N` or `Last-Event-ID: N`
preserves normal replay behavior, including `after=0` replaying the retained
history.

## Demo topology

```bash
herdr --session herdr-ios-fixtures server
python3 scripts/setup_herdr_demo.py --session herdr-ios-fixtures
```

This creates three repeatable demo workspaces with three panes each in the
isolated named session. Existing workspaces are reused only when their label,
fixture marker, and pane paths prove ownership. Missing panes are repaired and
extra panes are preserved. To opt into real AI processes:

```bash
python3 scripts/setup_herdr_demo.py \
  --session herdr-ios-fixtures \
  --start-agents \
  --agent-kind codex
```

Starting real agents may consume provider quota. The script therefore requires
the explicit `--start-agents` flag. Partial failures report every agent that
was started plus a scoped recovery command. Stop the complete fixture with
`herdr session stop herdr-ios-fixtures --json`.
