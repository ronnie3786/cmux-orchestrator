# Herdr Pi integration

This Pi package adds three integrations to the stock interactive TUI:

- a local, pane-specific semantic side channel for Pi processes launched by
  Herdr, without replacing or parsing the terminal;
- `/send-to-herdr`, which hands a persisted Pi session running outside Herdr to
  the local Herdr Harness and opens the resulting pane in the Mac app;
- `present_result`, an agent tool that explicitly registers a finished file or
  HTTP(S) link for the floating Herdr HUD. The Mac app shows only unviewed
  results and opens them with their native default application.

For an isolated local test, launch Pi through Herdr with this directory as a
temporary extension:

```bash
herdr agent start mobile-pi --kind pi --pane <pane-id> -- --extension \
  /absolute/path/to/cmux-orchestrator/pi-semantic-bridge
```

Equivalently, from an existing Herdr-managed shell whose environment contains
`HERDR_SOCKET_PATH` and `HERDR_PANE_ID`:

```bash
pi -e /absolute/path/to/cmux-orchestrator/pi-semantic-bridge
```

No global Pi settings are changed by either command. For durable installation,
`pi install /absolute/path/to/cmux-orchestrator/pi-semantic-bridge` is
idempotent because Pi records the local package path rather than copying or
modifying another extension.

## Send an existing session to Herdr

The package must be installed in Pi's user settings so the command is present
in sessions started outside Herdr. From a persisted Pi session, run:

```text
/send-to-herdr
```

Herdr resumes the exact session in workspace `Random`, tab `One-off Tasks`,
reusing either by an exact name match and creating it when missing. The command
first waits for Pi to become idle, then switches the source process to a blank
placeholder session. That releases the original session file before Herdr
starts it. The harness does not report success until the new pane's semantic
bridge is connected and reports the exact requested session ID.

After that readiness proof, the command opens `herdr://pane/<id>` and cleanly
exits the source Pi process. A known harness rejection restores the original
session locally and removes the blank placeholder. If a transport failure makes
the outcome unknowable, the original stays closed so two Pi processes cannot
write the same session file. The warning tells the user to check Herdr before
resuming manually. Successful handoffs remove any exact, empty placeholder file
after the source process exits, so it does not remain in Pi's session history.

Explicit Herdr IDs override either default destination:

```text
/send-to-herdr --workspace-id <workspace-id>
/send-to-herdr --tab-id <tab-id>
/send-to-herdr --workspace-id <workspace-id> --tab-id <tab-id>
```

Use `/send-to-herdr --help` for the same usage summary. The command requires a
persisted session and reads the local bearer token from the user-only
`~/.config/herdr-harness/api-token` file. It connects to
`http://127.0.0.1:9092` by default. A same-machine development harness on a
different loopback origin can be selected with `HERDR_SEND_TO_HERDR_URL` (or
the existing `HERDR_HARNESS_URL`). Redirects and non-loopback origins are
rejected so the bearer token cannot be forwarded elsewhere.

The command is deliberately a no-op inside an already Herdr-managed Pi pane.
Existing Pi processes started before installation can load the command with
`/reload`; newly started processes discover it automatically.

## Present finished results in the HUD

Herdr-managed interactive panes and headless Agent runs expose the
`present_result` tool to the model. Agents call it for intentional deliverables
such as documents, HTML pages, images, audio, video, and useful web links. They
do not infer attachments by scraping prose from a final answer, and they do not
register ordinary source edits, logs, or intermediate build products.

File locations may be absolute or relative to the Agent's working directory.
The harness validates the allowlisted file type, rejects symlinks and executable
content, then copies the bytes into private durable storage before publishing an
authenticated `result_artifact.created` event. Registration retries carry a
stable idempotency key, so a lost HTTP response cannot create duplicate HUD
nodes. The Mac independently rejects missing or oversized file metadata, caps
each transfer at 512 MiB, and refuses symlinked cache destinations before
opening a result. ASK-mode headless runs can present HTTP(S) links only; ACT runs and
interactive panes can also present finished local files.

The extension socket is derived from the complete Herdr socket path and a full
SHA-256 of `HERDR_PANE_ID`, so multiple Pi panes coexist safely. The socket is
created inside a dedicated user-only directory, and the harness independently
verifies its type, owner, and mode. Stale sockets are removed only when their
device and inode still match the failed connection probe.

The bridge sends forward-compatible protocol version 1 NDJSON. It projects the
active, compaction-aware session branch, strips provider signatures and private
agent setup data, and checkpoints the current transcript after every settled
agent run and before shutdown. The harness journals those checkpoints and a
bounded, contiguous suffix of ordered events in SQLite. Production starts use
`~/.config/herdr-harness/pi-semantic.sqlite3`; tests that inject an explicit
empty environment stay in memory. Records are namespaced by the normalized
Herdr socket path so identically named panes in different Herdr sessions cannot
share history.

The snapshot's `state` object also carries `context: { tokens, contextWindow, percent }` (the
active model's context usage, or nulls right after compaction before the next LLM
response), and `turn_end` events carry the same `context` object so clients can update
a live context meter during a run.

Authenticated harness routes for a detected Pi pane are:

- `GET /api/v1/panes/{paneId}/pi/snapshot`
- `GET /api/v1/panes/{paneId}/pi/events`
- `POST /api/v1/panes/{paneId}/pi/prompt`
- `POST /api/v1/panes/{paneId}/pi/steer`
- `POST /api/v1/panes/{paneId}/pi/follow-up`
- `POST /api/v1/panes/{paneId}/pi/abort`
- `POST /api/v1/panes/{paneId}/pi/compact`

Prompt, steer, follow-up, abort, and compact are delivered to the same Pi
process. Compact is accepted only while Pi is idle. Stock TUI extension dialogs
remain terminal-owned, so interaction responses are advertised as unsupported.
The terminal PTY path remains unchanged.
