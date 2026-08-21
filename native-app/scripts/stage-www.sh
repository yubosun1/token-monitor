#!/bin/bash
# Stage the renderer (original HTML/CSS/JS) plus the renderer-safe shared
# modules into a flat www/ tree the native app bundles.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WWW="$ROOT/native-app/build/www"

rm -rf "$WWW"
mkdir -p "$WWW/shared" "$WWW/icons"

# Renderer root (index.html, dashboard.html, styles, app modules)
cp -R "$ROOT/src/electron/renderer/." "$WWW/"

# Renderer-safe modules that live one level up in the Electron layout
cp "$ROOT/src/electron/windowShortcut.js" "$WWW/windowShortcut.js"
cp "$ROOT/src/electron/motionPreference.js" "$WWW/motionPreference.js"

# Shared scripts referenced by the pages (copied dynamically so the list
# can't drift from index.html/dashboard.html)
grep -ho 'src="../../shared/[^"]*"' "$WWW/index.html" "$WWW/dashboard.html" \
  | sed 's|src="../../shared/||; s|"||' \
  | sort -u | while read -r f; do
      [ -f "$ROOT/src/shared/$f" ] && cp "$ROOT/src/shared/$f" "$WWW/shared/$f"
  done

# Native build icon allowlist. Keep this aligned with KNOWN_CLIENTS,
# LIMIT_PROVIDERS and the two tray variants in renderer/app.js.
for icon in \
  claude codex opencode workbuddy proma hanako hanako-mask dsh deepseek \
  cursor gemini antigravity xai meta mistral qwen kimi zai cohere xiaomi minimax doubao hunyuan \
  tray-claude tray-codex tray-token-monitor; do
  cp "$ROOT/assets/icons/$icon.svg" "$WWW/icons/$icon.svg" 2>/dev/null \
    || cp "$ROOT/assets/icons/$icon.png" "$WWW/icons/$icon.png"
done
cp "$ROOT/assets/icons/hanako.png" "$WWW/icons/hanako.png"
cp "$ROOT/assets/icon.png" "$WWW/icon.png"

# Rewrite relative paths for the flattened layout — HTML and every staged
# JS/CSS file that references the repo-level assets/ dir.
find "$WWW" -maxdepth 1 \( -name '*.html' -o -name '*.js' -o -name '*.css' \) -print0 \
  | xargs -0 perl -pi -e 's{\.\./\.\./\.\./assets/icons/}{icons/}g;
                          s{\.\./\.\./\.\./assets/}{}g;
                          s{\.\./\.\./shared/}{shared/}g;
                          s{\.\./windowShortcut\.js}{windowShortcut.js}g;
                          s{\.\./motionPreference\.js}{motionPreference.js}g;
                          s{\.\./\.\./assets/}{}g'

echo "staged: $WWW"
