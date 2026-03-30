#!/usr/bin/env bash
# cmux-harness: Auto-approve Claude Code permission prompts
#
# Usage:
#   ./auto-approve.sh --all        # watch ALL workspaces (recommended)
#   ./auto-approve.sh 0            # watch workspace 0, surface 0
#   ./auto-approve.sh 0 1          # watch workspace 0, surface 1
#   DRY_RUN=1 ./auto-approve.sh 0  # detect but don't send
#   POLL_INTERVAL=2 ./auto-approve.sh 0

set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-5}"
SCREEN_LINES="${SCREEN_LINES:-40}"
WATCH_ALL=0
if [[ "${1:-}" == "--all" ]]; then
    WATCH_ALL=1
    WORKSPACE="all"
    SURFACE="0"
else
    WORKSPACE="${1:-0}"
    SURFACE="${2:-0}"
fi
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"

# Socket path - auto-detect
if [[ -n "${CMUX_SOCKET_PATH:-}" ]]; then
    CMUX_SOCKET="$CMUX_SOCKET_PATH"
elif [[ -S "$HOME/Library/Application Support/cmux/cmux.sock" ]]; then
    CMUX_SOCKET="$HOME/Library/Application Support/cmux/cmux.sock"
elif [[ -S "/tmp/cmux.sock" ]]; then
    CMUX_SOCKET="/tmp/cmux.sock"
else
    echo "Error: Cannot find cmux socket. Set CMUX_SOCKET_PATH."
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

log() { echo -e "${CYAN}[harness]${RESET} $*"; }
warn() { echo -e "${YELLOW}[harness]${RESET} $*"; }
debug() { [[ "$VERBOSE" == "1" ]] && echo -e "${DIM}[debug]${RESET} $*" || true; }
approved() { echo -e "${GREEN}[✓ approved]${RESET} $*"; }

# ── Socket Helper (Python) ─────────────────────────────────────────
# Runs multiple commands on a SINGLE socket connection.
# Saves current workspace, switches to target, does work, switches back.

HARNESS_PY=$(cat << 'PYEOF'
import socket, sys, time, json

SOCK_PATH = sys.argv[1]
TARGET_WS = sys.argv[2]
SURFACE = sys.argv[3]
LINES = sys.argv[4]
ACTION = sys.argv[5]  # "read" or "send_text:xxx" or "send_key:xxx"

def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(SOCK_PATH)
    return s

def cmd(s, c):
    s.sendall((c + '\n').encode())
    data = b''
    while True:
        try:
            chunk = s.recv(16384)
            if not chunk: break
            data += chunk
        except socket.timeout: break
    return data.decode('utf-8', errors='replace').strip()

s = connect()

# Get current workspace so we can switch back
current = cmd(s, 'current_workspace')

# Switch to target
cmd(s, f'select_workspace {TARGET_WS}')

if ACTION == 'read':
    result = cmd(s, f'read_screen {SURFACE} --lines {LINES}')
    print(result)
elif ACTION.startswith('send_text:'):
    text = ACTION[len('send_text:'):]
    result = cmd(s, f'send_surface {SURFACE} {text}')
    print(result)
elif ACTION.startswith('send_key:'):
    key = ACTION[len('send_key:'):]
    result = cmd(s, f'send_key_surface {SURFACE} {key}')
    print(result)

# Switch back to where we were (no visible flicker)
if current and current != 'ERROR':
    cmd(s, f'select_workspace {current}')

s.close()
PYEOF
)

read_screen() {
    python3 -c "$HARNESS_PY" "$CMUX_SOCKET" "$WORKSPACE" "$SURFACE" "$SCREEN_LINES" "read" 2>/dev/null
}

send_text() {
    python3 -c "$HARNESS_PY" "$CMUX_SOCKET" "$WORKSPACE" "$SURFACE" "$SCREEN_LINES" "send_text:$1" 2>/dev/null
}

send_key() {
    python3 -c "$HARNESS_PY" "$CMUX_SOCKET" "$WORKSPACE" "$SURFACE" "$SCREEN_LINES" "send_key:$1" 2>/dev/null
}

cmux_ping() {
    python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect('$CMUX_SOCKET')
s.send(b'ping\n')
data = b''
while True:
    try:
        chunk = s.recv(1024)
        if not chunk: break
        data += chunk
    except: break
s.close()
print(data.decode().strip())
" 2>/dev/null
}

# ── Prompt Detection ───────────────────────────────────────────────
detect_prompt() {
    local screen="$1"
    local last_lines
    last_lines=$(echo "$screen" | tail -25)

    # Pattern 1: Numbered menu with ❯ on "Confirm" or "Approve" — send Enter
    if echo "$last_lines" | grep -qE '❯.*(Confirm|Approve|Accept|Proceed|Continue)' && echo "$last_lines" | grep -q 'Enter to select'; then
        echo "confirm_menu"
        return 0
    fi

    # Pattern 2: Numbered menu with ❯ on "Yes" + "Esc to cancel" footer
    if echo "$last_lines" | grep -qE '❯.*Yes' && echo "$last_lines" | grep -q 'Esc to cancel'; then
        echo "yes_menu"
        return 0
    fi

    # Pattern 3: (Y/n) or (y/n) prompts
    if echo "$last_lines" | grep -qiE '\(Y/n\)|\(y/n\)|\(yes/no\)'; then
        echo "yn_prompt"
        return 0
    fi

    # Pattern 3: Tool approval — "Allow <ToolName>"
    if echo "$last_lines" | grep -qiE '(❯|>)?\s*Allow\s+(Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit|ListDir|Glob|Grep|TodoRead|TodoWrite|WebFetch|WebSearch|Search|Task|NotebookRead|NotebookEdit)'; then
        echo "tool_approval"
        return 0
    fi

    # Pattern 4: Yes/No button with ❯ on Yes/Allow
    if echo "$last_lines" | grep -qE '❯\s*(Yes|Allow)'; then
        echo "button_yes"
        return 0
    fi

    # Pattern 5: Generic allow/approve question
    if echo "$last_lines" | grep -qiE '(Allow|Approve).*(tool|action|command|operation)\?'; then
        echo "allow_generic"
        return 0
    fi

    # Pattern 6: Run/execute command
    if echo "$last_lines" | grep -qiE '(Run|Execute) (this|the) (command|script)\?'; then
        echo "run_command"
        return 0
    fi

    # Pattern 7: Apply changes/edits
    if echo "$last_lines" | grep -qiE '(Apply|Write|Save) (these |the )?(changes|edits|file)\?'; then
        echo "apply_changes"
        return 0
    fi

    # Pattern 8: Trust workspace
    if echo "$last_lines" | grep -qiE 'Do you (trust|want to allow)'; then
        echo "trust_prompt"
        return 0
    fi

    # Skip: Numbered menu where ❯ is NOT on an affirmative option (needs human choice)
    if echo "$last_lines" | grep -q 'Enter to select' && ! echo "$last_lines" | grep -qE '❯.*(Confirm|Approve|Accept|Proceed|Continue)'; then
        debug "Menu without affirmative option selected — skipping (needs human)"
        return 1
    fi

    return 1
}

send_approval() {
    local prompt_type="$1"

    case "$prompt_type" in
        confirm_menu|button_yes|yes_menu)
            if [[ "$DRY_RUN" == "1" ]]; then
                approved "DRY RUN: would send Enter to ws:$WORKSPACE surf:$SURFACE ($prompt_type)"
            else
                send_key "enter"
                approved "Sent Enter → ws:$WORKSPACE surf:$SURFACE ($prompt_type)"
            fi
            ;;
        *)
            if [[ "$DRY_RUN" == "1" ]]; then
                approved "DRY RUN: would send 'y' to ws:$WORKSPACE surf:$SURFACE ($prompt_type)"
            else
                send_text "y"
                approved "Sent 'y' → ws:$WORKSPACE surf:$SURFACE ($prompt_type)"
            fi
            ;;
    esac
}

# ── Main ───────────────────────────────────────────────────────────

log "cmux Auto-Approve Harness"
log "Socket: $CMUX_SOCKET"
log "Target: workspace $WORKSPACE, surface $SURFACE"
log "Poll: ${POLL_INTERVAL}s | Lines: $SCREEN_LINES"
[[ "$DRY_RUN" == "1" ]] && warn "DRY RUN mode — no keystrokes will be sent"

pong=$(cmux_ping || true)
if [[ "$pong" != "PONG" ]]; then
    echo "Error: Cannot connect to cmux socket."
    exit 1
fi
log "Connected ✓"

# Get workspace count for --all mode
get_workspace_count() {
    python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect('$CMUX_SOCKET')
s.send(b'list_workspaces\n')
data = b''
while True:
    try:
        chunk = s.recv(8192)
        if not chunk: break
        data += chunk
    except: break
s.close()
lines = [l.strip() for l in data.decode().strip().split('\n') if l.strip()]
print(len(lines))
" 2>/dev/null
}

if [[ "$WATCH_ALL" == "1" ]]; then
    ws_count=$(get_workspace_count)
    log "Watching ALL $ws_count workspaces (surface 0 each)"
else
    screen=$(read_screen 2>/dev/null || true)
    if [[ -n "$screen" ]]; then
        log "Target last line: $(echo "$screen" | tail -1 | head -c 80)"
    fi
fi
echo ""
log "Watching... (Ctrl+C to stop)"

# Track fingerprints per workspace
declare -A LAST_FINGERPRINTS

check_workspace() {
    local ws="$1"
    local surf="$2"

    # Temporarily override WORKSPACE for read/send functions
    local orig_ws="$WORKSPACE"
    WORKSPACE="$ws"

    local screen
    screen=$(read_screen 2>/dev/null || true)

    if [[ -z "$screen" ]]; then
        WORKSPACE="$orig_ws"
        return
    fi

    local prompt_type
    prompt_type=$(detect_prompt "$screen" 2>/dev/null || true)

    if [[ -n "$prompt_type" ]]; then
        local fingerprint
        fingerprint=$(echo "$screen" | tail -5 | md5 2>/dev/null || echo "$screen" | tail -5 | md5sum 2>/dev/null | cut -d' ' -f1)
        local last="${LAST_FINGERPRINTS[$ws]:-}"

        if [[ "$fingerprint" != "$last" ]]; then
            log "Detected in ws:$ws: $prompt_type"
            if [[ "$VERBOSE" == "1" ]]; then
                echo -e "${DIM}--- ws:$ws screen tail ---${RESET}"
                echo "$screen" | tail -10
                echo -e "${DIM}--- end ---${RESET}"
            fi
            SURFACE="$surf"
            send_approval "$prompt_type"
            LAST_FINGERPRINTS[$ws]="$fingerprint"
            sleep 1
        else
            debug "ws:$ws same prompt, already approved"
        fi
    else
        debug "ws:$ws no prompt"
    fi

    WORKSPACE="$orig_ws"
}

while true; do
    if [[ "$WATCH_ALL" == "1" ]]; then
        ws_count=$(get_workspace_count)
        for ((i=0; i<ws_count; i++)); do
            check_workspace "$i" "0"
        done
    else
        check_workspace "$WORKSPACE" "$SURFACE"
    fi

    sleep "$POLL_INTERVAL"
done
