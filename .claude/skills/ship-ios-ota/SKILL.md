---
name: ship-ios-ota
description: Build, sign, and publish the latest Herdr iOS app (herdr-harness-ios) to the Tailscale OTA install server and hand Ronnie the install link. Use after committing+pushing iOS changes, or whenever asked to "send a new iOS build", "push an OTA update", "new install link", or "ship the iOS app".
---

# Ship Herdr iOS over-the-air

OTA host is THIS machine (Tailscale node name `rocketbot`, even though `hostname` says
otherwise). Everything runs locally; the phone installs over the tailnet.

## Pre-flight

1. Changes committed and pushed to `origin/main`; iOS unit suite green:
   `cd herdr-harness-ios && xcodebuild -project herdr-harness-ios.xcodeproj -scheme herdr-harness-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:herdr-harness-iosTests`
2. Bump the build number so the install replaces cleanly — in
   `herdr-harness-ios/herdr-harness-ios.xcodeproj/project.pbxproj`, raise every
   `CURRENT_PROJECT_VERSION = N;` that belongs to the app + HerdPulseWidgets targets
   (they share one value; test targets stay at 1). Check the current value first, then e.g.
   `sed -i '' 's/CURRENT_PROJECT_VERSION = 4;/CURRENT_PROJECT_VERSION = 5;/g' <pbxproj>` —
   expect exactly 4 replacements. Commit the bump with the release.

## Build + sign (takes ~10 min; run in background)

Uses automatic signing with the paid team `L2M32HMQZH`; export method `debugging`
(the applinks entitlement cannot ride a wildcard profile). ExportOptions.plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>debugging</string>
	<key>teamID</key><string>L2M32HMQZH</string>
	<key>signingStyle</key><string>automatic</string>
	<key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
```

```bash
cd herdr-harness-ios
xcodebuild -project herdr-harness-ios.xcodeproj -scheme herdr-harness-ios \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/herdr.xcarchive archive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath /tmp/herdr.xcarchive \
  -exportPath /tmp/herdr-ipa -exportOptionsPlist <ExportOptions.plist path> \
  -allowProvisioningUpdates
```

## Publish + verify

```bash
cp /tmp/herdr-ipa/herdr-harness-ios.ipa ~/herdr-ota/herdr-harness.ipa
curl -sk -o /dev/null -w 'index:%{http_code} '  https://rocketbot.tail1db61d.ts.net:8462/
curl -sk -o /dev/null -w 'ipa:%{http_code} size:%{size_download}\n' https://rocketbot.tail1db61d.ts.net:8462/herdr-harness.ipa
```

All must be 200 and the served size must equal the local IPA byte count. If the IPA/index
fail: the `serve.py` process does not survive reboots — restart with
`nohup python3 ~/herdr-ota/serve.py >/dev/null 2>&1 &` (binds 127.0.0.1:8812; the
`tailscale serve --bg --https=8462 8812` mapping DOES persist and shows in
`tailscale serve status`). Moved from 8811 on 2026-08-21: a skylight-dashboard
calendar service (openclaw workspace) now owns 8811 — if the served size is a few
hundred bytes of calendar JSON, something re-took the port; check `lsof -nP -iTCP:8812`.

## Deliver

Install link (Safari on a tailnet device): **https://rocketbot.tail1db61d.ts.net:8462/**
It installs over the existing app, keeping pairing. `~/herdr-ota/manifest.plist`'s
`bundle-version` string (0.1) does not need touching for build-number-only releases.

## Gotchas

- Port 8461 on rocketbot is a STALE benchmark mapping — never point anything at it.
- The signed archive requires this machine (it holds the team's signing cert). Do not try
  to archive on the work Mac (no identities there).
