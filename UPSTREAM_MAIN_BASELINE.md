# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `bdeffba1bf162fe4a3952fdfba0050878e12f676`
- Upstream subject: `fix(copilot): keep token rate animation smooth during ticks (#637)`
- Reviewed on: `2026-09-10`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
fce070c789ae8b1ca59be3ce7c09fd8301d6f631..bdeffba1bf162fe4a3952fdfba0050878e12f676
```

## Reviewed Compatibility Notes

Only the most recent review round is kept here. Each new review must
replace the previous `Range ...` section, not append to it; older rounds
live in git history only.

Range `fce070c7..bdeffba1` (v0.55.0) reviewed on 2026-09-10:

- `3a3acac1` `fix(renderer): generalize hunyuan vendor rule to cover hy\d models (#617)`:
  Ported to `macos-native` (`src/electron/renderer/usageCharts.js`).
  Updated model vendor regex to match `hy\d|hunyuan` so newer Hunyuan model variants (hy2, hy3, etc.) map correctly to Hunyuan vendor.
- `0f4d1650` `fix(limits): prevent provider toggle flicker on save (#622)`:
  Ported to `macos-native` (`src/electron/renderer/app.js`).
  Added revision fencing (`limitProviderSelectionRevision` and `pendingLimitProviderSelection`) to ignore stale async settings responses and prevent checkbox flickering during rapid provider toggles.
- `4837c610` `feat(renderer): opt-in live token rate display (#621)`:
  Skipped — opt-in live token rate display was evaluated and removed as unnecessary for local requirements.
- Node.js provider refactorings (`ee51c68f`, `1516e87a`, `61329bf9`, `600fa324`, `eeb7fbef`, `e88703fe`, `98b8cba8`, `84b29bb8`, `ff956dd9`, `9c339ee8`, `c628e8c1`, `c922579b`, `6d2d14bc`, `c1743a65`):
  Skipped — `macos-native` runs a Swift native backend and does not use Node.js provider modules.
- `bdeffba1` `fix(copilot): keep token rate animation smooth during ticks (#637)`:
  Skipped — copilot token rate ticker adjustment.