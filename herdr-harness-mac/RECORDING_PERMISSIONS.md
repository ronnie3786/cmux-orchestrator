# Recording permission recovery

Herdr Settings includes **Screen & System Audio Recording**. Opening Settings checks existing access without requesting it. **Request Access** explicitly asks macOS for permission. **Test Access** verifies ScreenCaptureKit can enumerate displays without recording any screen pixels or audio. **Identify this copy of Herdr** shows the actual running application path and its signing identity.

If the toggle is on but Test Access fails:

1. Use **Reveal This Copy** and note the path. Keep a single installed copy at `/Applications/Herdr.app`.
2. Quit Herdr, including its menu bar and HUD.
3. In System Settings > Privacy & Security > Screen & System Audio Recording, remove the stale Herdr entry, then add `/Applications/Herdr.app` and enable it.
4. Launch that installed copy and use **Test Access**. Quit and reopen after any permission change if macOS requests it.

For a stale entry that cannot be removed normally, quit Herdr and run this app-specific reset in Terminal, then repeat the grant:

```sh
tccutil reset ScreenCapture dev.ronnierocha.herdr-harness.herdr-harness-mac
```

This resets only Herdr's screen recording decision. Do not reset all TCC permissions or edit the TCC database. The user must grant access in macOS; Herdr cannot grant it to itself.

## Why a previous toggle can stop working

The installed Work Mac copy inspected on September 6, 2026 uses `Signature=adhoc`, has no TeamIdentifier, and its designated requirement is a specific `cdhash`. Rebuilding changes that hash, so a permission granted to an older identity may no longer authorize the replacement. This can affect a Release build too. The prior deployment recipe builds Release with `CODE_SIGN_IDENTITY=-`.

Use the same Apple signing identity and bundle identifier for distributed builds. Developer ID signing and notarization are the intended release path. A debug build signed with a stable development certificate is not inherently unable to receive recording permission. Neither inspected Mac currently has a valid code-signing identity available, so release signing must be configured before distributing stable updates.

There is no existing screen-capture loop in this companion app's source. If an agent invokes another app or a separately launched capture helper, macOS may attribute the request to that process instead. Herdr's Test Access checks the companion app, not remote agents or helper executables. Grant the app named by the actual macOS request on the Mac performing the capture.

For a read-only identity report:

```sh
bash Scripts/diagnose-recording-permission.sh /Applications/Herdr.app
```
