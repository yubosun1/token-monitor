# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `f8fc74f9b642d18dcbaa0cfde683ee91aec00122`
- Upstream subject: `chore: release v0.51.0`
- Reviewed on: `2026-09-01`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
b89dce732040de98f024be71a4f04a70c7a11ce2..f8fc74f9b642d18dcbaa0cfde683ee91aec00122
```

## Reviewed Compatibility Notes

Only the most recent review round is kept here. Each new review must
replace the previous `Range ...` section, not append to it; older rounds
live in git history only.

Range `b89dce73..f8fc74f9` (v0.51.0) reviewed on 2026-09-01:

- `79e01325` `feat(dashboard): add per-tool model breakdown (#554)`:
  Deferred per maintainer decision — native branch removed its roots
  (`toolDetails.js`, `usageAttributionRows.js`) in the renderer trim, the
  bridge lacks `TokenMonitorToolDetails`, and the native stats payload carries
  no per-client model attribution (Swift `models` are pricing-only model IDs).
  Porting would require rebuilding the Swift data layer, bridge API, and
  renderer UI; ledger.db does hold (session, date, model) aggregation, so it
  remains possible if wanted later.
- `2389f5ab` `fix(dashboard): hide rounded-zero model remainders`:
  Companion fix for #554, skipped with it.
- `941bd2b3` `perf(renderer): suspend hidden and inactive rendering (#386)`:
  Skipped — native branch already achieves the equivalent with WebView
  reclamation after 30s hidden (`82481848`) plus adaptive polling
  (foreground 15s / background 180s); Electron-side material suspend and
  renderer-internal scheduling overlap with that, no port.
- `2ce7a9de` `feat(windows): add experimental taskbar z-order keeper (#548)`:
  Windows-only Electron (windowsForegroundHook.js / windowsTaskbarZOrder.js),
  not applicable; the renderer/i18n crumbs are for the Windows setting UI.
- `3841e828` `fix(renderer): render floating bubble at device scale (#559)`:
  Floating bubble and trayComposer.js were removed from the native branch
  (`bd72dc07`), not applicable.
- `1ca4175a` `fix(antigravity): repair stale sync locks (#568)`:
  Skipped — the upstream bug is a cross-process sync-lock file blocking the
  Antigravity scanner; the native scanner uses an in-process `NSLock` around
  its file cache (`Adapters.swift`) and has no sync-lock files, so the bug
  cannot occur. The renderer repair button depends on bridge APIs and a
  health note (`sync-lock-present`) that do not exist here.
- `44063bf7` `feat(antigravity): add standalone multi-account OAuth limits (#564)`:
  Skipped — native branch has no Antigravity quota/limits pipeline (Swift
  Limits covers DeepSeek/Kimi/subscriptions only).
- `b47d1264` `feat(codex): add optional reset forecast (#555)`:
  Skipped — Codex limits not enabled on `macos-native`.
- `3ead782e` `fix(codex): label gpt-reserve as Luna Reserve (#556)`:
  Skipped — Codex limits not enabled.
- `b9817716` `fix(renderer): resync tray visibility after reload`:
  Electron main-process tray behavior; native tray lives in Swift
  (`AppDelegate`), not applicable.
- `57633fb5` `docs(readme): add Homebrew installation`: docs, skipped.
- `73542b87` `test: guard WSL marker attribution and Discord Rich Presence client maps (#551)`:
  Test-only, skipped.
- `f8fc74f9` `chore: release v0.51.0`: release metadata, skipped.