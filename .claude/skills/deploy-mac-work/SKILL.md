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
ssh -o BatchMode=yes ronniesitym4mbp 'cd ~/Documents/Development/cmux-harness && git pull --ff-only 2>&1 | tail -1 && cd herdr-harness-mac && xcodebuild -project herdr-harness-mac.xcodeproj -scheme herdr-harness-mac -configuration Release -destination "platform=macOS" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build 2>&1 | grep -E " error:|BUILD (SUCCEEDED|FAILED)" && pkill -f "Herdr.app/Contents/MacOS"; sleep 1; REL=$(ls -dt ~/Library/Developer/Xcode/DerivedData/herdr-harness-mac-*/Build/Products/Release/herdr-harness-mac.app | head -1) && rm -rf /Applications/Herdr.app && cp -R "$REL" /Applications/Herdr.app && open -n /Applications/Herdr.app && sleep 4 && pgrep -f "Herdr.app/Contents/MacOS" | wc -l | tr -d " "'
```

Success = `BUILD SUCCEEDED` and a final `1` (one running process). Report the deployed
commit: `ssh ... 'git -C ~/Documents/Development/cmux-harness log --oneline -1'`.

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
