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
cp "$ROOT/src/electron/windowsBackdropMode.js" "$WWW/windowsBackdropMode.js"

# Shared scripts referenced by the pages (copied dynamically so the list
# can't drift from index.html/dashboard.html)
grep -ho 'src="../../shared/[^"]*"' "$WWW/index.html" "$WWW/dashboard.html" \
  | sed 's|src="../../shared/||; s|"||' \
  | sort -u | while read -r f; do
      [ -f "$ROOT/src/shared/$f" ] && cp "$ROOT/src/shared/$f" "$WWW/shared/$f"
  done

# Icons referenced by CSS/JS at runtime
cp -R "$ROOT/assets/icons/." "$WWW/icons/"
cp "$ROOT/assets/icon.png" "$WWW/icon.png"

# Rewrite relative paths for the flattened layout — HTML and every staged
# JS/CSS file that references the repo-level assets/ dir.
find "$WWW" -maxdepth 1 \( -name '*.html' -o -name '*.js' -o -name '*.css' \) -print0 \
  | xargs -0 perl -pi -e 's{\.\./\.\./\.\./assets/icons/}{icons/}g;
                          s{\.\./\.\./\.\./assets/}{}g;
                          s{\.\./\.\./shared/}{shared/}g;
                          s{\.\./windowShortcut\.js}{windowShortcut.js}g;
                          s{\.\./motionPreference\.js}{motionPreference.js}g;
                          s{\.\./windowsBackdropMode\.js}{windowsBackdropMode.js}g;
                          s{\.\./\.\./assets/}{}g'

echo "staged: $WWW"
