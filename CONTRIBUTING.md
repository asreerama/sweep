# Contributing to Sweep

Thanks for wanting to make Sweep better. This document is the contract for every change that lands here — human-written or agent-written. Sweep is a disk cleaner: a bug in most apps loses a frame, a bug here loses someone's files. The standards below exist for that reason and are not negotiable.

## Ground rules

1. **Read `PLAN.md` first.** It is the canonical architecture and safety document. Every module, tier, and gate referenced in code comments points back to it.
2. **Read-only by construction.** Scanning code must be incapable of writing — not disciplined about it, incapable. Nothing outside the gated clean/uninstall execution paths may import deletion machinery. If your change makes a read path able to write, it will be rejected regardless of tests.
3. **Deny wins. Trash first. No placebo.** Exclusions beat matches at any depth. Deletions go to Trash with a journal, never `unlink`. Features that fake value (a "free RAM" button on Apple Silicon) don't get built.
4. **Honest metrics.** Numbers shown to the user must be real (deduped by inode, tier-scoped). If a number can't be computed honestly, show nothing.

## Building and testing

```sh
swift build                  # all packages + app target
swift test                   # full suite — must be green before any PR
./scripts/build-app.sh       # signed .app bundle into ~/Applications
./scripts/make-fixtures.sh   # deterministic fake junk tree for scan testing
```

- macOS 15+ with Xcode's Swift 6 toolchain. The app targets macOS 26.
- One known timing-sensitive test: `UninstallerLogicTests.testSelectDroppedAppSelectsAnOrdinaryAppAndLoadsLeftovers` walks the real `~/Library` under a 15s budget and can fail under heavy disk load. If it fails in a full run, rerun it isolated — an isolated pass counts.
- UI changes are verified with the offscreen snapshot harness (no screen needed):
  ```sh
  SWEEP_SNAPSHOTS=/tmp/shots SWEEP_HOME=<fixture-dir> SWEEP_SNAPSHOT_EXIT=1 \
    ~/Applications/Sweep.app/Contents/MacOS/Sweep
  ```
  Attach before/after captures to any PR that changes pixels.

## Repository structure

| Target | Role | Depends on |
|---|---|---|
| `Packages/SweepPolicy` | Path policy, denylist, XPC protocol — the safety vocabulary | nothing |
| `Packages/SweepCore` | Scan engine, rule catalog, clean service, deletion journal | SweepPolicy |
| `Packages/SweepSystem` | Memory/CPU/disk sampling (menubar + Memory screen) | nothing |
| `Packages/SweepUninstall` | App inventory + leftover matching (read-only) | SweepPolicy |
| `Packages/SweepUI` | Design system: tokens, motion, shared components | nothing |
| `Sources/SweepApp` | The app shell, screens, models | all of the above |
| `SweepHelper` | Privileged helper daemon — talks to the app **only** over XPC | SweepPolicy |
| `Sources/SweepMenu` | Standalone menubar process (memory budget reasons) | SweepSystem |

Boundary rules that PRs must not blur:
- `SweepUI` depends on nothing and never imports SweepCore. Screens bind real data to it through adapters (see `CleanAdapter.swift` for the pattern).
- The app and the helper never import each other's code — XPC only.
- `SweepCore`'s pinned contracts (`CleanService`, `CleanEvent`, journal formats) don't change without an adversarial review pass; adapters absorb drift.

## Coding standards

These are the observed, enforced conventions of this codebase. Diffs that ignore them get sent back.

- **Comments carry the *why*, not the what.** Every non-obvious decision gets a doc comment explaining the reasoning, the alternative that was rejected, and — where one exists — the measurement or review finding that motivated it (`// Codex G1 finding #6`, `// PLAN §5`). If you fixed a bug, the comment explains the mechanism so it can't silently regress.
- **Design tokens only.** Colors come from `SweepTokens`, type from `SweepFont`, spacing from the `s1–s7` scale, motion from `SweepMotion`. A literal color, font size, or animation curve in a screen is a review failure. New visual vocabulary means a new token with a doc comment, not an inline value.
- **Swift 6 strict concurrency.** Models are `@MainActor @Observable`; anything crossing threads is `Sendable`; blocking filesystem work runs on dedicated threads (see `ScanWorkerPool`), never the cooperative pool.
- **State is owned once.** Screen-independent state (scan model, toolbox models) lives on `AppState`, not per-screen `@State` — the shell rebuilds screens on navigation, and screen-owned models re-trigger their loads every visit.
- **Every logic change ships with unit tests.** Pure logic is extracted so it is testable without the filesystem (`UninstallLogic`, `MemoryScreenLogic` are the pattern). Filesystem behavior is tested against fixtures built in temp dirs, never against the developer's real home.
- **Performance claims come with numbers.** A "faster" PR includes the measurement (what, on what tree, before/after wall time).

## For agent-assisted contributions

Agent-written PRs are welcome — much of Sweep was built that way — and are held to exactly the same bar, with two additions:

1. **Include verification evidence in the PR description**: full test-suite output, snapshot-harness captures for UI changes, benchmark numbers for perf changes. "The agent said it works" is not evidence.
2. **Keep the diff scoped.** No drive-by refactors, no comment rewrites outside the change, no reformatting. One concern per PR. If your agent touched files unrelated to the stated change, fix that before opening the PR.

## Submitting a PR

1. Fork, branch from `main` (`feature/<short-name>` or `fix/<short-name>`).
2. Make the change to the standards above.
3. Run the full suite; capture evidence.
4. Open the PR using the template — the checklist there is the merge gate.

### PR checklist (mirrored in the template)

- [ ] `swift build` and `swift test` pass locally (flaky-test rule above applied)
- [ ] New/changed logic has unit tests
- [ ] UI changes include before/after snapshot-harness captures (light and dark)
- [ ] No literal colors/fonts/spacing/curves — tokens only
- [ ] Comments explain *why*, and cite `PLAN.md` sections or review findings where relevant
- [ ] Read-only boundaries intact (no write capability added to scan/inventory paths)
- [ ] Package dependency rules intact (`SweepUI` imports nothing; app↔helper XPC only)
- [ ] Perf changes include before/after measurements
- [ ] Diff contains only the stated change

## Reporting issues

Use the issue templates. For scan-correctness bugs (wrong size, wrong attribution, something claimed that shouldn't be), include the tree structure that reproduces it — `scripts/make-fixtures.sh` shows the shape of a good reproduction.

## Security

Sweep deletes files for a living. If you find a way to make it delete something it shouldn't — a symlink escape, a TOCTOU window, a policy bypass — do not open a public issue. Email aditya.sreerama@gmail.com directly.
