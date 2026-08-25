#!/bin/zsh
set -u

timestamp="$(date +%Y%m%d-%H%M%S)"
folder="$HOME/Library/Logs/Herdr/hang-$timestamp"
mkdir -p "$folder"

pid="$(pgrep -f 'herdr-harness-mac.app/Contents/MacOS' | head -1)"
if [[ "${1:-}" == "--post-mortem" || -z "$pid" ]]; then
  diagnostics_dir="$HOME/Library/Containers/dev.ronnierocha.herdr-harness.herdr-harness-mac/Data/Library/Logs/Herdr"
  if [[ -d "$diagnostics_dir" ]]; then
    cp -R "$diagnostics_dir" "$folder/container-logs" || print 'Container diagnostics copy failed (non-fatal).' >> "$folder/container-logs-copy.txt"
  else
    print 'No container diagnostics directory found (non-fatal).' > "$folder/container-logs-copy.txt"
  fi
  log show --last 30m --predicate 'subsystem == "dev.ronnierocha.herdr-harness"' --style compact > "$folder/perf-log-30m.txt" 2>&1 || print 'Log capture failed (non-fatal).' >> "$folder/perf-log-30m.txt"
  print "Post-mortem hang capture written to: $folder"
  exit 0
fi

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
