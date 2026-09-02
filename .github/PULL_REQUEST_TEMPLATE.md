## What

<!-- One paragraph: what changes and why. Cite PLAN.md sections if the change touches architecture or safety. -->

## Evidence

<!-- Paste full `swift test` output (or the tail with totals). For UI: before/after snapshot-harness captures, light + dark. For perf: before/after numbers and what tree they were measured on. -->

## Checklist

- [ ] `swift build` and `swift test` pass locally (see CONTRIBUTING.md for the one known flaky test's isolation rule)
- [ ] New/changed logic has unit tests
- [ ] UI changes include before/after snapshot-harness captures (light and dark)
- [ ] No literal colors/fonts/spacing/curves — `SweepTokens`/`SweepFont`/`SweepMotion` only
- [ ] Comments explain *why*, citing PLAN.md / review findings where relevant
- [ ] Read-only boundaries intact — no write capability added to scan/inventory paths
- [ ] Package dependency rules intact (`SweepUI` imports nothing; app↔helper via XPC only)
- [ ] Perf changes include measurements
- [ ] Diff contains only the stated change (no drive-by refactors)
- [ ] Agent-assisted? Verification evidence included per CONTRIBUTING.md
