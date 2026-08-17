# Upstream Main Review Baseline

- Upstream remote: `https://github.com/Javis603/token-monitor.git`
- Local `main` synchronized through: `88a2927bd93aa5ad943717c6257858bc5048c115`
- Upstream subject: `fix(antigravity): detect quoted Windows CLI paths (#440)`
- Reviewed on: `2026-08-17`
- Native branch: `macos-native`

This is a review baseline, not a claim that `macos-native` contains every
upstream change. For the next upstream review, start with:

```text
88a2927bd93aa5ad943717c6257858bc5048c115..upstream/main
```

## Reviewed Compatibility Note

Upstream commit `5ad5c9974429c7464a40a88ca453b633327265bb`
(`fix(renderer): hide zero-value unclassified residual rows (#439)`) was not
ported. The native renderer does not generate synthetic unclassified residual
rows: its tool and model lists only render entries with positive token values.
Adding the upstream helper would therefore be dead code in this branch.
