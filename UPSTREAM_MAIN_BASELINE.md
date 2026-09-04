# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `fce070c789ae8b1ca59be3ce7c09fd8301d6f631`
- Upstream subject: `chore: release v0.54.0`
- Reviewed on: `2026-09-05`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
0b17b1ec53ccd60508a645144ccb7db74027168c..fce070c789ae8b1ca59be3ce7c09fd8301d6f631
```

## Reviewed Compatibility Notes

Only the most recent review round is kept here. Each new review must
replace the previous `Range ...` section, not append to it; older rounds
live in git history only.

Range `0b17b1ec..fce070c7` (v0.54.0) reviewed on 2026-09-05:

- `8b179039` `fix(widget): stabilize titlebar hover controls (#608)`:
  Ported to `macos-native` (`src/electron/renderer/styles.css`, `app.js`).
  Restricted `.actions-hotspot` to top-right corner with `clip-path` to avoid
  overlapping the period tabs, reduced leave transition delay to 140ms, and
  added pointer-focus blur (`event.detail > 0`) on pin and close buttons to
  prevent sticky focus from keeping controls visible after cursor leaves.
- `4a280443` `feat(unsloth): add Unsloth Studio usage tracking (#606)`:
  Skipped — Unsloth Studio tracking via Tokscale SQLite is out of scope for
  `macos-native`'s trimmed core client set.
- `73bd3535` `fix(renderer): keep views live behind settings (#609)`:
  Skipped (N/A) — `macos-native` already decoupled settings into a lightweight
  CSS overlay and does not suspend main stats surface rendering while settings
  is open.
- `70fdcd8a` `feat(alibaba): add Token Plan limits for Team and Personal consoles (#604)`:
  Skipped — Alibaba Token Plan limits provider is not needed in `macos-native`;
  native limits polling currently focuses on DeepSeek balance and Kimi membership.
- `e9df2c8a` `fix(codex): show reset type in forecast details (#610)`:
  Skipped — `macos-native` does not integrate third-party `codexResetForecast`.
- `347fbee5` `refactor(renderer): drop the settings catch-up repaints (#611)`:
  Skipped (N/A) — related to #609; `macos-native` does not perform redundant
  catch-up repaints on settings toggle.
- `fce070c7` `chore: release v0.54.0`: release metadata, skipped.