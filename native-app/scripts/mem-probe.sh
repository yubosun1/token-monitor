#!/bin/bash
# Memory probe (PLAN.md round-4 Phase 5): build the Release app, run it
# against the real user data, wait for the first full collection, then
# capture the main process physical footprint and a heap snapshot for
# __DataStorage / UsageRow analysis.
#
#   scripts/mem-probe.sh [run-dir] [settle-seconds]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/native-app"
BUNDLE="$ROOT/dist/Token Monitor.app"
BIN="$BUNDLE/Contents/MacOS/TokenMonitor"
RUN_DIR="${1:-$APP_DIR/.perf/mem-probe-$(date +%Y%m%d-%H%M%S)}"
SETTLE="${2:-75}"

echo "building app..."
"$APP_DIR/scripts/build-app.sh" >/dev/null

if pgrep -f "Token Monitor.app/Contents/MacOS/TokenMonitor" >/dev/null; then
  echo "error: a Token Monitor instance is already running" >&2
  exit 1
fi

mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/app.log"
echo "launching (settle ${SETTLE}s)..."
env TOKEN_MONITOR_DIAG=1 TOKEN_MONITOR_DIAG_DIR="$RUN_DIR" "$BIN" >"$LOG" 2>&1 &
APP_PID=$!
echo "$APP_PID" > "$RUN_DIR/app.pid"

sleep "$SETTLE"
/usr/bin/footprint -p "$APP_PID" > "$RUN_DIR/footprint.txt" 2>&1 || echo "footprint unavailable" > "$RUN_DIR/footprint.txt"
/usr/bin/heap "$APP_PID" > "$RUN_DIR/heap.txt" 2>&1 || echo "heap unavailable" > "$RUN_DIR/heap.txt"

kill "$APP_PID" 2>/dev/null || true
sleep 2
pkill -f "[R]esources/tokscale" 2>/dev/null || true

echo "--- summary ($RUN_DIR) ---"
grep -c 'tokscale spawn' "$LOG" || true
echo "footprint (tail):"; tail -12 "$RUN_DIR/footprint.txt" | head -12
echo "__DataStorage (heap):"; grep -c '__DataStorage' "$RUN_DIR/heap.txt" || true
echo "UsageRow (heap):"; grep -c 'UsageRow' "$RUN_DIR/heap.txt" || true
echo "run dir: $RUN_DIR"