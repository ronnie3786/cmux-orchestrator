#!/bin/bash
#
# check-ios-drift.sh — informational parity report for the Mac port.
#
# The port doctrine (PORT_PLAN.md §2) says files carried over from the iOS app
# are copied byte-identical. This script finds every Mac .swift file that has an
# identically-named counterpart in the iOS tree and diffs the pair, so drift in
# a file that is *supposed* to be verbatim shows up before it becomes a bug.
#
# Pairs are derived mechanically by file *basename*, not by path, because the
# Mac shell moved a few files between directories on purpose.
#
# Always exits 0 — this is a report, not a gate.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_ROOT="$REPO_ROOT/herdr-harness-mac"
IOS_ROOT="$(cd "$REPO_ROOT/.." && pwd)/herdr-harness-ios/herdr-harness-ios"

if [[ ! -d "$MAC_ROOT" ]]; then
    echo "check-ios-drift: no Mac sources at $MAC_ROOT" >&2
    exit 0
fi

if [[ ! -d "$IOS_ROOT" ]]; then
    echo "check-ios-drift: no iOS reference tree at $IOS_ROOT — skipping." >&2
    exit 0
fi

identical=()
drifted=()
drift_stats=()
mac_only=()

while IFS= read -r mac_file; do
    base="$(basename "$mac_file")"

    # An iOS basename can in principle appear more than once; take the first
    # match in a stable (sorted) order so the report is reproducible.
    ios_file="$(find "$IOS_ROOT" -name "$base" -type f 2>/dev/null | sort | head -1)"

    if [[ -z "$ios_file" ]]; then
        mac_only+=("${mac_file#"$MAC_ROOT"/}")
        continue
    fi

    if cmp -s "$mac_file" "$ios_file"; then
        identical+=("${mac_file#"$MAC_ROOT"/}")
    else
        drifted+=("${mac_file#"$MAC_ROOT"/}")
        stat_line="$(diff -U0 "$ios_file" "$mac_file" \
            | grep -c '^+[^+]' || true)"
        del_line="$(diff -U0 "$ios_file" "$mac_file" \
            | grep -c '^-[^-]' || true)"
        drift_stats+=("+${stat_line} -${del_line}")
    fi
done < <(find "$MAC_ROOT" -name '*.swift' -type f | sort)

echo "iOS parity drift report"
echo "  mac: $MAC_ROOT"
echo "  ios: $IOS_ROOT"
echo

echo "PORTED-IDENTICAL (${#identical[@]})"
for f in "${identical[@]:-}"; do
    [[ -n "$f" ]] && echo "  $f"
done
echo

echo "DRIFTED (${#drifted[@]}) — same filename, different bytes"
for i in "${!drifted[@]}"; do
    printf '  %-72s %s\n' "${drifted[$i]}" "${drift_stats[$i]}"
done
echo

echo "MAC-ONLY (${#mac_only[@]}) — no iOS file of that name"
for f in "${mac_only[@]:-}"; do
    [[ -n "$f" ]] && echo "  $f"
done
echo

echo "summary: ${#identical[@]} identical · ${#drifted[@]} drifted · ${#mac_only[@]} mac-only"

exit 0
