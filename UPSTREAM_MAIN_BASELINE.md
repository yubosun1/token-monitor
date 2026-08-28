# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `7c74e61fd8f9d592e647f14107738746a51e49ff`
- Upstream subject: `chore: release v0.49.0`
- Reviewed on: `2026-08-28`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
7c74e61fd8f9d592e647f14107738746a51e49ff..upstream/main
```

## Reviewed Compatibility Notes

Range `6121585f..7c74e61f` (v0.49.0) reviewed on 2026-08-28:

- `a3dd42d4` `fix(installer): grant AppContainer read access to the install directory (#522)`:
  Windows-only NSIS installer + Chromium sandbox ACL, not applicable.
- `6e27a0e3` `fix(settings): preserve normalized values on update (#441)`:
  Not applicable — touches `src/electron/main.js` and `windowBehavior.js`, which do not
  exist on `macos-native`; window behavior lives in `SettingsStore.swift` with no
  equivalent re-spread bug pattern.
- `df48ed2c` `chore(deps): update js-yaml to 4.3.2 (#436)`:
  Lockfile-only security bump (GHSA-5p4m-2wfm-xmqj); branch has no `package.json` /
  js-yaml dependency.
- `582596e0`, `566e6578` `feat(volcengine)`: track Agent Plan alongside Coding Plan and
  show its daily quota (#490, #532):
  Skipped — Volcengine provider not enabled on `macos-native`.
- `12bf86aa` `fix(grok): read WSL credentials for limits (#530)`:
  Skipped — WSL-only path and grok provider not enabled.
- `e4305f81` `fix(trae): handle untouched and feature-only entitlement packs (#515)`:
  Skipped — Trae provider not enabled (earlier trae limits were deferred).
- `3e82f76a` `feat(cursor): add managed multi-account support (#523)`:
  Skipped — Cursor provider not enabled on `macos-native`.
- `3e80f82b` `chore(tokscale): retire the vendored override for upstream 4.14.0 (#517)`:
  Skipped — branch has no vendored tokscale pin (`scripts/vendor/tokscale.json` absent);
  tokscale is a standalone Swift build.
- `7c74e61f` `chore: release v0.49.0`: release metadata, skipped.

Range `7ad2acce..6121585f` (v0.48.0) reviewed on 2026-08-26:

- `6bfac460` `feat(limits): add Sub2API-compatible account preset to third-party APIs (#476)`:
  Skipped per maintainer preference (not needed).
- `c493a209` `feat(kimi): integrate Kimi Work usage and project attribution (#453)`:
  Skipped — `macos-native` has its own native Kimi collector, ledger, and model token breakdown.
- `af634791` `fix(tokscale): pin latest upstream and align usage semantics (#501)`:
  Skipped — native branch uses custom Swift collector & standalone tokscale build.
- Electron/Node-specific architecture fixes (`5ecc6053` #486, `a4302988` #495, `76cf94b0` #499, `2a88aa03` #500):
  Not applicable to `macos-native` (native Swift multi-threading, ARC/autoreleasepools, and SQLite history ledger handle watcher and collector lifecycle).
- `5be24d32` `fix(trae): align account setup UI`: Trae limits not enabled in native branch.
- `a22e1744`, `e4f2619b`, `b9258659`: UI/test cosmetic updates, skipped.


Range `bed9fc32..7ad2acce` (v0.47.0) reviewed on 2026-08-22:

- `a0af301e` `feat(workbuddy): add local app credits monitoring (#378)`:
  Removed per user preference (WorkBuddy credits monitoring disabled/removed).
- `1519ecf7` `feat(tray): add balance meter percentage option (#470)`:
  Ported to `macos-native`. Updated `trayLayout.js`, `trayComposer.js`, and
  `i18n.js` to support selecting `creditsDisplay: 'percent'` on credits/balance items.
- `b98fb089` `feat(cherrystudio)` (#387), `7ad2acce` `feat(trae)` (#483),
  `cc79febc` `fix(codex)` (#473): deferred per maintainer request.
- Electron-specific fixes (`#464`, `#467`, `1558506b`): not applicable or
  handled natively in Swift.

Range `88a2927b..bed9fc32` (v0.46.0) reviewed on 2026-08-19:

- DSH usage tracking (#408) and DSH session detail (#427): not ported as-is —
  the native branch has its own Swift DSH pipeline (incremental zstd
  streaming, event-time attribution, per-(turn, step) model attribution).
  Two correctness fixes from upstream's implementation WERE ported to the
  Swift collector/detail instead:
  - fork `seedLength` prefix skip (`seq < seedLength` events belong to the
    parent session only);
  - corrupt zstd frame prefix preservation (a checksum-damaged frame no
    longer zeroes out the whole session).
  Uncompressed `session.jsonl` support was deliberately skipped: no such
  files exist on the maintainer's machine. `DSH_HOME` env override and
  detail-pane `source.kind` filtering were deliberately skipped.
- `6a620c44` `fix(claude): honor CLAUDE_CONFIG_DIR (#455)`: deliberately not
  ported — the native collector hardcodes `~/.claude` and the maintainer does
  not use a custom config dir.
- Home heatmap hover fixes (`fe99b3f8`, `0da144e6` #452): deliberately not
  ported — the native dashboard overview lists every model/client (no top-5
  cap) and scrolls instead; the hover scale effect is kept as-is.
- Windows-only fixes (#442, #444, #345, #447), Hub draft fix (#433), and the
  vendored-tokscale release bridge (#448, #449): not applicable to the
  macOS-native branch.

Upstream commit `5ad5c9974429c7464a40a88ca453b633327265bb`
(`fix(renderer): hide zero-value unclassified residual rows (#439)`) was not
ported. The native renderer does not generate synthetic unclassified residual
rows: its tool and model lists only render entries with positive token values.
Adding the upstream helper would therefore be dead code in this branch.
