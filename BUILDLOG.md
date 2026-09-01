# Sweep build log (autonomous overnight run, started 2026-09-01 ~00:00)

User mandate: build to completion overnight, no questions. Gates enforced. Opus spend-capped:
Sonnet agents + Fable review + Codex (raw `codex exec`, plugin wrapper broken) for gate reviews.

## Wave status

- [x] P0 research · P1 scaffold · P2 engines (Codex-reviewed, 18 findings fixed) · M1
- [x] P3 UI wave read-only · M2 (commit e3a8fb1)
- [x] WAVE-G1 built + wired. Design recalibrations applied (palette v2 indigo SaaS,
      volume raise, motion continuity frame-verified, ring proportions). M2 shipped to user.
- [ ] GATE-1 security loop (running): Codex review 1 -> 7 findings fixed (e1522d9) ->
      re-check verdict GATE: HOLD -> fix loop 2 in flight (catalog byte-pinning, trashItem
      decoy verification via slot FD, journal append fail-closed, WAL trusted anchor +
      nlink==1, sealed SelectionBatch, identity-bound adapter, clone Codable removal,
      quarantine scan gaps) -> verdicts 3,4 fixed surgically by Fable -> verdict 5
      GATE: OPEN -> gate flipped, M3 SHIPPED (trash-only cleaning live in ~/Applications).
- [x] WAVE-P4: SweepHelper (HELPER: OPEN, cleared by Codex re-check; live SMAppService
      registration = human step), Uninstaller + AppCleaner parity (drop targets, SmartDelete
      watcher), Developer + Homebrew screens, clone-detector UI. Gate U held twice by Codex
      (signed-evidence, durable consent, transactional rollback), fix loop 2 in flight.
- [x] WAVE-P5: menubar split (Sweep Menu.app, 45.4 MB idle < 50 budget), onboarding + FDA
      capability model. Integration commit e520de1, all suites green.
- [ ] Gate 2 build (direct-delete safe-tier + fault-injection suite) in flight.
- [~] SUPERSEDED: SweepHelper (SMAppService + XPC codesign validation, maintenance ops),
      Uninstaller screen + AppCleaner parity (Dock/window drop targets, SmartDelete watcher,
      quit-first), Developer + Homebrew screens, clone-detector UI wiring, menubar
      accessory-mode switch + 50MB budget measurement.
- [ ] GATE-2: fault-injection suite green -> direct deletion for safe-tier caches. M4.
- [ ] WAVE-P5: onboarding (FDA capability model), settings, motion polish, Instruments.
- [ ] WAVE-P6: rule-by-rule audit, review agents, real-machine trash-only trial, budgets,
      final signed build. M5.

## Pinned API contract (G1, agents code against this)

SweepCore exposes: `CleanService` — `static isEnabled` (Fable flips post-review),
`execute(_ request: CleanRequest) -> AsyncThrowingStream<CleanEvent>`; CleanRequest built
ONLY from catalog rules + scanned candidates (rule-authorized per finding #9), trash-only,
safe-tier enforced inside; WAL journaled; report carries per-item outcomes + Trash restore
URLs + honest freed-bytes (capacity delta). UI shows: confirm sheet -> progress (counter
rolls down) -> report.

## Known issues in flight

- macOS 26 titlebar corruption >32,767pt scroll content: fix = bounded group expansion (B).
- Smart Scan must filter to safe tier before clean (B + A enforce independently).

## Model tiering (user mandate 2026-09-01)
Haiku = mechanical (catalogs, fixtures, boilerplate, docs). Sonnet = implementation + research. Opus = security/architecture-critical only (currently spend-capped). Fable = orchestrate, review, glue. Terse status output.
