# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `bed9fc32e17ffcd165f98cb8da4b68fdfed220a9`
- Upstream subject: `chore: release v0.46.0`
- Reviewed on: `2026-08-19`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
bed9fc32e17ffcd165f98cb8da4b68fdfed220a9..upstream/main
```

## Reviewed Compatibility Notes

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
