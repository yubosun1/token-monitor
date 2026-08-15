#!/bin/bash
# Round-4 Phase 5 runtime probe: run the app with a short collection
# interval and verify unchanged DSH session files are never re-decompressed.
# Counts per-run decompress lines and distinct decompressed paths; a file
# must appear at most once across several full checks.
#
#   scripts/dsh-redecompress-probe.sh [run-dir] [duration]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/native-app"
BUNDLE="$ROOT/dist/Token Monitor.app"
BIN="$BUNDLE/Contents/MacOS/TokenMonitor"
RUN_DIR="${1:-$APP_DIR/.perf/dsh-probe-$(date +%Y%m%d-%H%M%S)}"
DURATION="${2:-130}"
SETTINGS="$HOME/Library/Application Support/Token Monitor/settings.native.json"
BACKUP="$RUN_DIR/settings-backup.json"

"$APP_DIR/scripts/build-app.sh" >/dev/null
if pgrep -f "Token Monitor.app/Contents/MacOS/TokenMonitor" >/dev/null; then
  echo "error: a Token Monitor instance is already running" >&2
  exit 1
fi
mkdir -p "$RUN_DIR"
cp "$SETTINGS" "$BACKUP"
restore() { cp "$BACKUP" "$SETTINGS"; }
trap restore EXIT

python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
data['refreshMs'] = 5000
data['collectionIntervalMs'] = 15000
with open(path, 'w') as f: json.dump(data, f, indent=2, sort_keys=True)
print('settings tweaked: refreshMs=5000 collectionIntervalMs=15000')
PYEOF

env TOKEN_MONITOR_DIAG=1 TOKEN_MONITOR_DIAG_DIR="$RUN_DIR" "$BIN" >"$RUN_DIR/app.log" 2>&1 &
APP_PID=$!
echo "$APP_PID" > "$RUN_DIR/app.pid"
sleep "$DURATION"
kill "$APP_PID" 2>/dev/null || true
sleep 2
pkill -f "[R]esources/tokscale" 2>/dev/null || true
restore
trap - EXIT

DECOMP=$(grep -c '\[dsh\] decompress' "$RUN_DIR/app.log" || true)
DISTINCT=$(grep '\[dsh\] decompress' "$RUN_DIR/app.log" | awk '{print $NF}' | sort -u | wc -l | tr -d ' ' || true)
FULLS=$(grep -c 'source tokscale: fingerprint unchanged\|changed' "$RUN_DIR/app.log" || true)
echo "--- summary ($RUN_DIR) ---"
echo "decompress events: $DECOMP"
echo "distinct decompressed files: $DISTINCT"
echo "run dir: $RUN_DIR"