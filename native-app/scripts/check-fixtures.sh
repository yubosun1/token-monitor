#!/bin/bash
# Run the committed aggregation fixture checker (PLAN.md Phase 0).
# Compares the collector's periods/history composition against committed
# golden files; exits non-zero on any difference.
#
#   scripts/check-fixtures.sh            # compare against goldens
#   TM_GOLDEN_UPDATE=1 scripts/check-fixtures.sh   # regenerate goldens
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/native-app"

export TMPDIR="$APP_DIR/.tmp"
export SWIFTPM_MODULECACHE_OVERRIDE="$APP_DIR/.cache"
mkdir -p "$TMPDIR" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift run --package-path "$APP_DIR" --disable-sandbox TokenMonitorFixtureCheck

