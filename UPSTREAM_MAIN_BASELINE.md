# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `05a5bf6cab3ae70e02248b69f168df4551fca523`
- Upstream subject: `feat(settings): search the tracked-tools and limit-provider lists (#590)`
- Reviewed on: `2026-09-03`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
f8fc74f9b642d18dcbaa0cfde683ee91aec00122..05a5bf6cab3ae70e02248b69f168df4551fca523
```

## Reviewed Compatibility Notes

Only the most recent review round is kept here. Each new review must
replace the previous `Range ...` section, not append to it; older rounds
live in git history only.

Range `f8fc74f9..05a5bf6c` (v0.52.0) reviewed on 2026-09-03:

- `d0a2b696` `fix(limits): align info icons with text`:
  Ported to `macos-native` (`src/electron/renderer/styles.css`). Removed the
  `transform: translateY(-1px)` from `.limit-detail-tooltip-wrap` so info icons
  align with text.
- `bd1fe833` `fix(limits): seed initial providers from detected tools (#566)`:
  Skipped — `macos-native` limits are handled natively in Swift (`SettingsStore.swift`,
  `KimiLimits.swift`, `DeepseekBalance.swift`) for DeepSeek and Kimi only, with no Node
  tool-discovery seeding pipeline.
- `f2cc6655` `fix(settings): disable Hub Save for unchanged drafts (#445)`:
  Skipped — Hub synchronization and related settings UI were completely removed on
  `macos-native`.
- `36307e7e` `feat(export): add daily model CSV (#573)`:
  Skipped — `macos-native` does not retain the Node-side CSV/JSON export engine (`exporter.js`);
  session and usage history is kept in the native SQLite ledger (`ledger.db`).
- `da4da77e` `feat(codex): allow hiding additional quotas (#577)`:
  Skipped — Codex limits not enabled on `macos-native`.
- `a00c5c62`, `29e57134` `feat(zed): add dashboard billing limits (#580)` and UI fix:
  Skipped — Zed limits are not implemented on `macos-native` (Swift limits pipeline covers
  DeepSeek/Kimi only).
- `c540bec3` `feat(window): hide the taskbar/Dock icon (#587)`:
  Skipped — `macos-native` was architected as an `LSUIElement` accessory app from the start
  (`Info.plist`), living exclusively in the menu bar with no Dock icon.
- `be197e44` `feat(models): rank models by tokens or cost (#585)`:
  Deferred per maintainer decision — `macos-native` trimmed `usageAttributionRows.js` and
  sorts models directly by token count; cost ranking requires porting barScaleMax and
  extending `SettingsStore.swift`.
- `05a5bf6c` `feat(settings): search the tracked-tools and limit-provider lists (#590)`:
  Skipped — upstream needs list searching for its 27 clients and 23 limit providers,
  whereas `macos-native` is trimmed to 8 clients and 2 limit providers where a search
  filter is unnecessary overhead.
- `a2ff67a5` `chore: release v0.52.0`: release metadata, skipped.