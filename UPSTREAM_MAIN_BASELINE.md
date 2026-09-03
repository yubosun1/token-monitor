# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `0b17b1ec53ccd60508a645144ccb7db74027168c`
- Upstream subject: `chore: release v0.53.0`
- Reviewed on: `2026-09-04`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
05a5bf6cab3ae70e02248b69f168df4551fca523..0b17b1ec53ccd60508a645144ccb7db74027168c
```

## Reviewed Compatibility Notes

Only the most recent review round is kept here. Each new review must
replace the previous `Range ...` section, not append to it; older rounds
live in git history only.

Range `05a5bf6c..0b17b1ec` (v0.53.0) reviewed on 2026-09-04:

- `689a8f6b` `refactor(renderer): one base type size and one rule for hiding (#593)`:
  Ported to `macos-native` (`src/electron/renderer/styles.css`, `dashboard.css`).
  Replaced scattered per-element `.hidden` rules with a blanket `.hidden, [hidden] { display: none !important; }`
  rule, added base font size `body { font-size: 11px; }`, set explicit `font-size: 16px;` on glyph buttons,
  and preserved display modes with `!important` on animated-out containers (`.settings-panel.hidden`,
  `.view-switcher-menu.hidden`).
- `dc20dc9a` `fix(cursor): probe the home-relative Tokscale cache (#563)`:
  Skipped — Windows-only home-relative cache probe fix for Node-side `collector.js`,
  which does not exist on `macos-native`.
- `f0d29620` `chore(deps): update tokscale to 4.15.1 (#596)`:
  Skipped — upstream tokscale bump addresses Cursor upstream connection changes,
  Command Code v3, and DSH summary counts in the tokscale CLI. In `macos-native`,
  Cursor and Command Code are not tracked, DSH is decoded natively in Swift
  (`Adapters.swift`), and the vendored tokscale 4.13.0 binary remains stable for
  Claude/Codex/WorkBuddy session scanning.
- `00ded791` `docs(readme): use animated third-party icon`:
  Skipped — upstream Electron README asset change; `macos-native` maintains its
  own dedicated README.
- `3d053449` `fix(renderer): map Muse models to Meta icon (#598)`:
  Skipped per maintainer decision — Meta / Muse models not used or tracked.
- `0b17b1ec` `chore: release v0.53.0`: release metadata, skipped.