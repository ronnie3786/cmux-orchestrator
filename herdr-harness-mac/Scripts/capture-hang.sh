#!/bin/zsh
set -u

pid="$(pgrep -f 'herdr-harness-mac.app/Contents/MacOS' | head -1)"
if [[ -z "$pid" ]]; then
  print -u2 'Herdr Mac is not running. Launch herdr-harness-mac, then rerun this script before force-quitting.'
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
folder="$HOME/Library/Logs/Herdr/hang-$timestamp"
mkdir -p "$folder"

sample "$pid" 10 -file "$folder/sample.txt"
footprint "$pid" > "$folder/footprint.txt" 2>&1
vmmap -summary "$pid" > "$folder/vmmap-summary.txt" 2>&1
heap "$pid" -sortBySize 2>&1 | head -60 > "$folder/heap.txt" || print 'heap capture failed (this is non-fatal).' >> "$folder/heap.txt"
log show --last 15m --predicate 'subsystem == "dev.ronnierocha.herdr-harness"' --style compact > "$folder/perf-log.txt" 2>&1

if sudo -n true 2>/dev/null; then
  sudo -n spindump "$pid" 5 -file "$folder/spindump.txt"
else
  print 'Skipped spindump: passwordless sudo is unavailable.' > "$folder/spindump.txt"
fi

print "Hang capture written to: $folder"
print 'Main thread hint:'
awk '/Call graph:/ { found = 1; next } found && count < 15 { print; count++ }' "$folder/sample.txt"
