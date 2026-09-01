# Sweep build log (autonomous overnight run, started 2026-09-01 ~00:00)

User mandate: build to completion overnight, no questions. Gates enforced. Opus spend-capped:
Sonnet agents + Fable review + Codex (raw `codex exec`, plugin wrapper broken) for gate reviews.

## Wave status

- [x] P0 research · P1 scaffold · P2 engines (Codex-reviewed, 18 findings fixed) · M1
- [x] P3 UI wave read-only · M2 (commit e3a8fb1)
- [ ] WAVE-G1 (running): A=SweepCore CleanService trash-only + #9 authorization pipeline;
      B=UI bounded groups (32k fix) + safe-tier Smart Scan + confirm/progress/report flow;
      C=standalone screens (Large&Old, Memory, Startup) — Fable wires into shell after.
      Then: Fable review -> Codex adversarial review -> fix -> flip CleanService gate -> M3.
- [ ] WAVE-P4: SweepHelper (SMAppService + XPC codesign validation, maintenance ops),
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
