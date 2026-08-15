#!/bin/bash
# Performance baseline capture (PLAN.md Phase 0 item 5).
#
#   scripts/perf-baseline.sh [run-dir] [mode]
#     run-dir  where logs/samples/dumps land (default native-app/.perf/<ts>)
#     mode     diag | tray (default diag; diag opens the windows and logs
#              [perf] phase timing + tokscale spawns, tray runs windowless)
#
# CPU and footprint come from the app's own [perf] marks (external ps/top
# is blocked in some environments); the script additionally counts app
# instances and WebKit child processes via pgrep and takes one external
# /usr/bin/footprint snapshot at the end.
#
# Environment: PERF_DURATION seconds to sample (default 150).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/native-app"
BUNDLE="$ROOT/dist/Token Monitor.app"
BIN="$BUNDLE/Contents/MacOS/TokenMonitor"
RUN_DIR="${1:-$APP_DIR/.perf/$(date +%Y%m%d-%H%M%S)}"
MODE="${2:-diag}"
DURATION="${PERF_DURATION:-150}"

echo "building app..."
"$APP_DIR/scripts/build-app.sh" >/dev/null

if pgrep -f "Token Monitor.app/Contents/MacOS/TokenMonitor" >/dev/null; then
  echo "error: a Token Monitor instance is already running" >&2
  exit 1
fi

mkdir -p "$RUN_DIR/dumps"
LOG="$RUN_DIR/app.log"
echo "launching ($MODE mode, ${DURATION}s)"
if [ "$MODE" = "diag" ]; then
  env TOKEN_MONITOR_DIAG=1 TOKEN_MONITOR_DIAG_DIR="$RUN_DIR/dumps" "$BIN" >"$LOG" 2>&1 &
else
  "$BIN" >"$LOG" 2>&1 &
fi
APP_PID=$!
echo "$APP_PID" > "$RUN_DIR/app.pid"

PROCS="$RUN_DIR/procs.csv"
echo "ts,instances,webkit_procs,tokscale_procs" > "$PROCS"
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  TS=$(date +%s)
  INST=$(pgrep -f "Token Monitor.app/Contents/MacOS/TokenMonitor" | wc -l | tr -d ' ') || true
  WK=$(pgrep -f 'com.apple.WebKit' | wc -l | tr -d ' ') || true
  TSP=$(pgrep -f '[R]esources/tokscale' | wc -l | tr -d ' ') || true
  echo "$TS,$INST,$WK,$TSP" >> "$PROCS"
  sleep 1
done

/usr/bin/footprint -p "$APP_PID" > "$RUN_DIR/footprint.txt" 2>&1 || echo "footprint unavailable" > "$RUN_DIR/footprint.txt"
pgrep -fl '[R]esources/tokscale' > "$RUN_DIR/tokscale-ps.txt" || true

kill "$APP_PID" 2>/dev/null || true
sleep 2
pkill -f "[R]esources/tokscale" 2>/dev/null || true

echo "--- summary ($RUN_DIR) ---"
echo "app log: $(wc -l < "$LOG" | tr -d ' ') lines"
LAUNCH=$(grep 'process launched' "$LOG" | head -1 || true)
FIRST_PUSH=$(grep 'push stats:push' "$LOG" | head -1 || true)
echo "launch:        ${LAUNCH:-none}"
echo "first push:    ${FIRST_PUSH:-none}"
if [ -n "$LAUNCH" ] && [ -n "$FIRST_PUSH" ]; then
  T0=$(echo "$LAUNCH" | awk '{print $2}')
  T1=$(echo "$FIRST_PUSH" | awk '{print $2}')
  python3 - "$T0" "$T1" <<'PYEOF'
import sys, datetime as dt
def parse(s):
    fmt = "%H:%M:%S.%f" if "." in s else "%H:%M:%S"
    return dt.datetime.strptime(s, fmt)
d = (parse(sys.argv[2]) - parse(sys.argv[1])).total_seconds()
print(f"startup to first stats push: {d:.1f}s")
PYEOF
fi
echo "tokscale spawns: $(grep -c 'tokscale spawn' "$LOG" || true)"
echo "--- phases / cpu / footprint (diag marks) ---"
grep -E '\[perf\] (refresh|phase|tokscale spawn|push|cpu|footprint|single-instance)' "$LOG" | head -60
echo "--- processes ---"
awk -F, 'NR>1 { if ($2>m1) m1=$2; if ($3>m2) m2=$3; if ($4>m3) m3=$4 } END { printf "instances max=%d webkit procs max=%d tokscale procs max=%d\n", m1, m2, m3 }' "$PROCS"
echo "footprint (external, tail):"; tail -20 "$RUN_DIR/footprint.txt" | head -20
echo "run dir: $RUN_DIR"

