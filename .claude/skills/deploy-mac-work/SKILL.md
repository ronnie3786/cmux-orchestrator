---
name: deploy-mac-work
description: Deploy the latest Herdr Mac app (herdr-harness-mac) to Ronnie's Doximity work Mac over Tailscale SSH — pull, Release build, install to /Applications, relaunch. Use after committing+pushing Mac app changes, or whenever asked to "update the work mac", "install the mac app on my work machine", or "push the new mac build".
---

# Deploy Herdr Mac to the Doximity work Mac

Target machine: `ronniesitym4mbp` (Tailscale node; MDM-enrolled Doximity Mac, user `ronnierocha`).
SSH works non-interactively: `ssh -o BatchMode=yes ronniesitym4mbp '<cmd>'`.

## Pre-flight

1. All changes must be committed and pushed to `origin/main` first (the work Mac pulls from
   the public GitHub repo `ronnie3786/cmux-orchestrator` over plain HTTPS — no credentials
   needed; that machine's `gh` token and SSH key for the personal account are expired/broken,
   which is fine for pulls, but do not rely on push access from there).
2. Verify the local unit suite is green before shipping:
   `cd herdr-harness-mac && xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -destination 'platform=macOS' test -only-testing:herdr-harness-macTests`
   (If the runner hangs silently >5 min: `pkill -9 testmanagerd`, retry.)

## Deploy (one SSH command, verified pattern)

```bash
ssh -o BatchMode=yes ronniesitym4mbp 'cd ~/Documents/Development/cmux-harness && git pull --ff-only 2>&1 | tail -1 && cd herdr-harness-mac && xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -configuration Release -destination "platform=macOS" -derivedDataPath ~/herdr-deploy-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build 2>&1 | grep -E " error:|BUILD (SUCCEEDED|FAILED)" && pkill -f "Herdr.app/Contents/MacOS"; sleep 1; APP=~/herdr-deploy-dd/Build/Products/Release/herdr-harness-mac.app && rm -rf /Applications/Herdr.app && cp -R "$APP" /Applications/Herdr.app && open -n /Applications/Herdr.app && sleep 4 && pgrep -f "Herdr.app/Contents/MacOS" | wc -l | tr -d " "'
```

Success = `BUILD SUCCEEDED` and a final `1` (one running process). Report the deployed
commit: `ssh ... 'git -C ~/Documents/Development/cmux-harness log --oneline -1'`.

**Never select the app via `ls -dt DerivedData/herdr-harness-mac-*`** — on 2026-08-25 that
pattern silently installed a day-old binary from a stale sibling DerivedData dir (its dir
mtime sorted first, and `cp -R` re-stamps mtimes so the installed binary *looked* fresh).
Always build with the explicit `-derivedDataPath ~/herdr-deploy-dd` and install from there.
To confirm the right build shipped, grep a symbol you know is new:
`strings /Applications/Herdr.app/Contents/MacOS/herdr-harness-mac | grep -c <NewTypeName>`.

## Post-deploy verification

The app writes diagnostics (since commit 431d0897) to the sandbox container:
`~/Library/Containers/dev.ronnierocha.herdr-harness.herdr-harness-mac/Data/Library/Logs/Herdr/`
— `vitals.log` gets a `event=periodic` line every 30s (footprint, main CPU, run-state,
backlogs, last checkpoint) and `hangs/` collects per-incident hang reports with symbolicated
main-thread backtraces. After deploying, wait ~40s and `tail` vitals.log over SSH: a healthy
launch shows `mainCPU` in low single digits and `terminalBacklog=0 piBacklog=0`. If the old
process was frozen, its final hang report (status INPROGRESS, finalized on next launch) is
the first thing to read.

## Notes / gotchas

- The repo clone on that machine is `~/Documents/Development/cmux-harness` (folder name differs
  from the repo name — do not clone a duplicate; one at `~/code/ronnie3786/` was removed already).
- Ad-hoc signing (`CODE_SIGN_IDENTITY=-`) is required: the work Mac has zero codesigning
  identities. Fine for a locally built app.
- Pairing survives reinstall (Keychain + UserDefaults). Server URL on that machine is
  `http://localhost:9092`; token lives at `~/.config/herdr-harness/api-token`.
- `git pull --ff-only` is safe: that clone carries only untracked local files (artifacts/, docs).
  If it ever refuses, inspect `git status` — never force.
- Xcode there is ≥26.6; build takes ~2-4 min.
- The Python harness (port 9092) is launchd-managed: `com.ronnierocha.herdr-harness`, launched
  via `~/.config/herdr-harness/launch-herdr-harness.sh`, which (since 2026-08-20) cds into
  `~/Documents/Development/cmux-harness` — the SAME clone this skill pulls. After backend
  (`herdr_harness/`) changes, restart it: `launchctl kickstart -k gui/$(id -u)/com.ronnierocha.herdr-harness`
  (sessions live in the separate `herdr-server`; a harness restart only blips SSE).
- `herdr_harness/static/herdr-web` is a gitignored Vite bundle (built from `frontend/herdr-web`);
  it was copied into this clone on 2026-08-20 — rebuild/copy it if `/herdr-web` ever 404s.
- Do NOT touch `~/Documents/Development/cmux-herdr-harness` — an older duplicate checkout with
  another session's uncommitted WIP (protocol-aware subscriptions); pane wV:p1 owns it.
