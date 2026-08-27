# Pi semantic bridge

This Pi package adds a local, pane-specific semantic side channel to the stock
interactive TUI. It does not replace or parse the terminal.

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
