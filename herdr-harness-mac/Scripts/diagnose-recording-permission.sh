#!/bin/bash
# Read-only. Run on the Mac experiencing the issue, with the exact installed app.
set -euo pipefail

HERDR_DIAGNOSTIC_APP="${1:-/Applications/Herdr.app}"
if [[ ! -d "$HERDR_DIAGNOSTIC_APP" ]]; then
    echo "App not found: $HERDR_DIAGNOSTIC_APP" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HERDR_DIAGNOSTIC_APP/Contents/Info.plist"
/usr/bin/codesign --display --verbose=4 --requirements - "$HERDR_DIAGNOSTIC_APP" 2>&1
/usr/bin/codesign --verify --strict --verbose=2 "$HERDR_DIAGNOSTIC_APP" 2>&1
echo 'Available signing identities:'
/usr/bin/security find-identity -v -p codesigning
echo 'This command does not reset permissions. In Herdr Settings, use Screen & System Audio Recording > Test Access.'
