# Sweep: Build Plan

Native macOS cleaning utility, CleanMyMac quality. Free, personal, no polish compromise.
Working codename: **Sweep** (rename one-line change until M3).

Status: v1.0, research complete (2026-08-31).

---

## 0. Landscape (research findings)

**No open-source tool match CleanMyMac end-to-end.** Gap real:

- **Pearcleaner** (14.5k stars, source-available): closest visual match, uninstall + orphan cleanup only, on hold since late 2025.
- **Stats** (41.5k stars, MIT, active): best menubar monitor, zero cleaning. One slice open source nailed.
- **Mole** (65.6k stars, GPL): broad cleaning but CLI-only; GUI separate paid product.
- **OnyX**: freeware, deep maintenance, dated checkbox UI, no smart scan or monitor.
- **PureMac / MacSai / Quitty**: young repos, CleanMyMac-alternative claims, suspect star patterns; skim for ideas, trust nothing.

Repos to mine during build: Pearcleaner (below), Stats (Mach/IOKit/SMC sensor reading, reference for SweepSystem), Mole (junk path checklist), xcode-dev-cleaner (Xcode cleanup logic).

### Pearcleaner deep dive (cloned, explored 2026-08-31)

Status corrected: README say "On Hold", repo say maintenance mode (2026-01-05 commit).
Maintainer reason, verbatim from README + Discussion #562: new job + friend's SaaS + life priorities, plus "I previously relied on my work MacBook for development. After changing jobs, I no longer have access to a Mac device that I can use for personal development work." Not code problems, not burnout: no time, no Mac.
Timeline: last real release v5.4.3 2025-11-26, last code merge 2026-01-30, "On Hold" README note 2026-05-11; issues since Feb 2026 (#544-#599) zero maintainer replies.
Known macOS 26 (Tahoe) breakage unaddressed: #589 (app exits when launched via Raycast/`open`), #533 (Applications/Utilities apps not listed). 109 Swift files, ~47k lines, no tests. Warning: pearcleaner.com fake malware site; real site itsalin.com.

Why nobody build on it: Commons Clause forbids selling anything whose value derives substantially from code, so no commercial party or indie has incentive to adopt; one genuine continuation, `lukeskyscraper8/Pearcleaner` fork (32 commits ahead, own v5.4.4 release 2026-07-11, actively maintained fixes), has 9 stars, invisible next to 14.5k-star "On Hold" upstream. Watch fork for fixes, including any Tahoe ones.

Worth mining (knowledge, not wholesale code; license Apache 2.0 + Commons Clause, no-sell condition):

- `Views/DevelopmentView.swift` `PathLibrary`: 25+ dev environments, curated cache paths (Xcode incl. all DeviceSupport variants, JetBrains, VS Code/Cursor/Zed, nvm/bun/pnpm, gradle, conda, uv...). Caution: mixes true caches with user data (`Code/User` is settings, `~/.cargo` holds installed binaries, `/nix/store` must never be raw-deleted); classify per-path into our tiers, never copy blind.
- `Logic/Locations.swift`: leftover-search root list including non-obvious gems (Crashlytics/Sparkle/Sentry/Segment caches, LSSharedFileList recent docs, Steam appmanifests).
- `Logic/Conditions.swift`: battle-tested per-app include/exclude fixes (Xcode vs xcodes vs "cleaner for xcode" disambiguation, VS Code vs Insiders). Hardcoded Swift; ours stays declarative JSON, port content.
- `Logic/AppPathsFetch.swift` (900-line AppPathFinder): matching = alphanumeric normalization + name/bundle-id containment + depth-limited walks + Spotlight supplement. Works but monolithic; reimplement clean in SweepUninstall.
- `PearcleanerSentinel` (80 lines): FSEvents watch on ~/.Trash triggers uninstall offer, ~2 MB RAM. Great pattern; add "auto-cleanup on app trash" to backlog.
- `PearcleanerHelper` + `CodesignCheck.swift`: XPC client validation by code signature = pattern our P4 needs. Their interface: generic `runCommand(String)` root executor, exactly what our closed-enum XPC design forbids. Copy validation, not interface.

## 1. Engine decision

**Swift 6 + SwiftUI, AppKit escape hatches where SwiftUI weak.** Non-negotiable:

- Menubar agent must idle under ~50 MB, near-0% CPU. Electron idles 200+ MB; Flutter ships own raster pipeline. Native only option meeting bar.
- Deep cleaning needs raw macOS APIs: TCC / Full Disk Access, SMAppService privileged helper, XPC, host_statistics64, IOKit. All first-class only in Swift/ObjC.
- CleanMyMac itself native. Matching feel requires same substrate: NSVisualEffectView materials, Core Animation springs, ProMotion 120 Hz.

Toolchain on this machine: macOS 26.5.2, Xcode 26.6, Swift 6.3.3. Target macOS 15+.

## 2. Architecture

Single Xcode project, local SPM packages per subsystem. One app process switching activation policy (regular when main window open, accessory otherwise) plus optional privileged daemon.

```
Sweep.xcodeproj
├── Sweep/                  App target: SwiftUI shell, menubar (MenuBarExtra/NSStatusItem)
├── SweepHelper/            Privileged daemon (SMAppService), XPC, audited op allowlist
└── Packages/
    ├── SweepCore/          Scan engine, rules engine, safety layer, deletion journal
    ├── SweepSystem/        Live stats: RAM, CPU, disk, network, battery (Mach + IOKit)
    ├── SweepUninstall/     App inventory, leftover matching by bundle id
    └── SweepUI/            Design system: tokens, components, motion primitives
```

Key contracts:

- **Rules engine (SweepCore).** Junk detection is data, not code: declarative rule catalog, each rule = fixed base root + allowed item types + owner UID + min age + app-running precondition + action type + undo capability + exclusions + rationale + safety tier. Tiers: `safe` (auto-selected), `caution` (surfaced, unselected), `expert` (hidden by default). Ambiguous rule defaults to `caution` until rule-specific audit proves `safe`. Catalog ships read-only inside signed bundle, versioned schema, deny-wins precedence, unknown fields/actions rejected. Schema frozen before catalog authoring (P1).
- **Safety layer (SweepCore).** Authorization = deny-by-default: operation-specific allowlisted roots resolved from system APIs, in small shared policy package used identically by app + helper (no lexical path checks; symlinks/case/Unicode/firmlinks handled via resolved identity). No raw `rm`. User-visible files go to Trash (`FileManager.trashItem`, record returned Trash URL for restore). Direct deletion only for tier-`safe` cache paths. Journal = versioned write-ahead log: operation IDs, file identities, planned/started/committed states, per-item results, `fsync`, abort-on-journal-failure; same-volume atomic quarantine rename before removal where possible. Every candidate stores volume ID + device/inode + type + link count + parent identity + timestamps; identity revalidated at delete time via `openat`/`fstatat(AT_SYMLINK_NOFOLLOW)`/`unlinkat`, refuse anything changed since scan. All mutation flows through one non-public `DeletionCoordinator` consuming immutable versioned `DeletionPlan`; feature packages = read-only candidate producers, never touch `FileManager` for writes. Hard denylist regardless of tier: ~/Documents, ~/Desktop, ~/Pictures, iCloud Drive, `~/Library/CloudStorage` + all File Provider domains (detect placeholders independently of pathname, never materialize during scan, no automatic actions on cloud-backed roots), Photos library, Sweep itself, Apple/system apps, SIP paths, any app bundle outside explicit uninstall.
- **Helper (SweepHelper).** Registered lazily via `SMAppService.daemon` only when user first requests system-level operation. XPC interface = closed enum of operations validated against same shared policy package; helper derives paths from validated UIDs/bundle IDs, never accepts caller-selected absolute paths. Caller auth: `NSXPCListener.setConnectionCodeSigningRequirement(_:)` bound to Sweep's identifier + signing cert before delegate accepts, plus UID/session validation; client verifies helper back. Lifecycle state machine + versioned XPC handshake (protocol/app/helper/policy versions), idempotent request IDs, timeouts, incompatible-version refusal, unregister/re-register recovery. Prototyped as P1 security spike, tested against unsigned + wrongly signed clients.
- **Scan engine.** Swift Concurrency, one actor per volume walk on dedicated blocking threads (off cooperative pool), fts enumeration with `FTS_PHYSICAL | FTS_XDEV` mandatory, `URLResourceKey.totalFileAllocatedSizeKey` for on-disk size with hardlink dedup (device/inode/link count) + APFS clone-family awareness; show bounds where shared extents prevent certainty; "freed" reported only from post-operation volume-capacity deltas. `VolumePolicy` pins volume UUID/device: local + writable + non-backup by default, network/backup/external volumes explicit opt-in, unmount mid-operation = first-class cancellation. Progress streamed via AsyncSequence.
- **Command execution.** Typed adapters only: fixed absolute executable paths, argument arrays, never shell interpretation; sanitized env/cwd, timeout, output cap, parsed exit status. User-tool commands (`brew`, `xcrun`) run as user, never root; helper reserved for minimal audited root-only set. Rule-specific process preflight before deletion: user-approved graceful quit, post-quit verification, `launchctl bootout` where appropriate, destructive operations serialized globally + per volume, identities revalidated after processes stop.
- **Result semantics.** Per-item `planned/succeeded/failed/skipped/changed` states, measured post-op bytes; parent never reported complete when children failed; permission denial vs policy refusal vs disappearance vs filesystem error distinguished in journal + UI.

## 3. Feature scope

### Information architecture (user-set hierarchy, 2026-08-31)

Focus = cleaning + making Mac efficient. Two-tier sidebar:

- **Primary (guided, opinionated, safe defaults):**
  - Smart Scan (hero, default view)
  - CLEAN group: System Junk, Large & Old Files
  - SPEED group: Memory, Maintenance, Startup Items
  - APPS group: Uninstaller (+ Orphans lens)
- **Toolbox (advanced, user-driven, visually quieter section at sidebar bottom):**
  Developer, Homebrew; later Packages, Plugins, Lipo, File Search.

Contract: primary modules may auto-select tier-`safe` items and feed Smart Scan. Toolbox modules NEVER auto-select anything, never appear in Smart Scan, always preview-first, expose maximum control. Menubar surfaces only primary signals (pressure, disk, quick actions).

### v1.0 modules

1. **Smart Scan.** One click: System Junk (safe tier) + safe maintenance. Hero moment of app. Empty Trash NEVER auto-selected: separate irreversible operation, second confirmation showing count/bytes/volumes, item identities snapshotted at review, anything added after review skipped.
2. **System Junk.** User caches, logs, Xcode (DerivedData, DeviceSupport, old simulators), Homebrew cache, npm/pnpm/yarn/pip caches, browser caches, Trash on all volumes.
   Plus **stale code-sign clones** (user-requested 2026-08-31, mechanics from disk-cleanup skill): macOS clones app bundle to `$DARWIN_USER_TEMP_DIR/../X/<bundle-id>.code_sign_clone` on every launch and leaks old ones on app self-update; Electron apps worst (Chrome, Codex; ~21 GB apparent seen on this machine). Not a catalog glob rule (needs per-item dynamic predicate): code-driven detector in SweepCore. Per clone: derive bundle id from dirname, skip if that app is running (NSRunningApplication) or clone <10 min old, size honestly (CoW: report apparent + note real reclaim is unique blocks only), tier safe, regenerates on next launch. Current user only in v1 (other accounts need the P4 helper). Implementation queued after the SweepCore fix batch merges.
3. **Memory.** Honest RAM module: live pressure, compressor stats, top consumers, one-click quit of heavy apps. No placebo "boost" claims; show real numbers.
   Research confirmed: `purge` (root, `/usr/sbin/purge`) flushes disk buffer cache only, never anonymous/compressed app memory; MacPaw itself documents its "Free up RAM" task as Intel-only. On Apple Silicon ship no purge action at all; only legitimate "free memory" action = quit heavy apps. Honesty = differentiator.
   Metrics: `host_statistics64(HOST_VM_INFO64)` for breakdown, `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` for pressure level, `proc_listpids` + `proc_pid_rusage` (`ri_phys_footprint`) for per-process footprint.
4. **Large & Old Files.** Volume scan, size/age filters + sort, reveal + trash actions.
5. **Uninstaller.** Full removal: bundle + leftovers matched by bundle id across `~/Library/{Application Support, Caches, Preferences, Containers, Group Containers,
   Saved Application State, LaunchAgents, WebKit, HTTPStorages}`, plus `/Library/LaunchDaemons` and `pkgutil` receipts. Every candidate carries auditable ownership evidence: signed bundle ID, receipt relationship, declared app-group entitlement, other installed consumers. Never auto-select name-only matches, shared Group Containers, LaunchDaemons, or orphans. Never uninstall Sweep itself or Apple/system apps; never `pkgutil --forget` as implicit cleanup. Process preflight: quit app + bootout its agents before bundle removal. Orphan detection tier `caution`, never `safe` (helper tools, licensed-but-uninstalled apps = false positives). No macOS API lists an app's files; glob-over-known-locations = what every uninstaller uses. `~/Library/Group Containers` gained SIP protection on macOS 15, deletions there can fail; handle gracefully, report, never silently skip.
6. **Startup Items.** Inventory + reveal + deep-link to System Settings for modern background items. Enable/disable ONLY where documented public API exists (own `SMAppService` items; legacy `LSSharedFileList` login-item APIs deprecated, do not use). Public-API boundary prototyped before committing toggle UI.
7. **Menubar monitor.** Live RAM/CPU/disk/network, memory-pressure gauge, quick actions (free memory, open main app; Empty Trash opens confirmation, never immediate). Measure post-scan retained memory + steady-state CPU at M1; if 50 MB idle budget missed, split minimal unprivileged menubar login item from main UI (decision gate, not afterthought).
8. **Maintenance.** Flush DNS, rebuild Spotlight (mdutil), thin APFS snapshots. Purgeable space shown as estimate only; reclaim is OS's job, no fake "free purgeable" action. `lsregister -kill -r` dropped (undocumented internal tool, violates documented-APIs-only rule).
9. **Homebrew.** GUI over brew (Pearcleaner-style, user-requested): installed formulae + casks list with sizes, outdated view + upgrade, cache cleanup (`brew cleanup --prune=all`), orphaned dependencies (`brew autoremove` preview), doctor output. Read-mostly; all mutations via typed command adapters as user, preview-first.
10. **Developer.** Dedicated actionable view over dev environments (Pearcleaner PathLibrary pattern, user-requested): per-environment groups (Xcode, JetBrains, VS Code/Cursor/Zed, node/nvm/bun/pnpm, gradle, cargo, conda, uv...) with live sizes, per-path tier badges (cache vs user data), select + clean. Same rules engine underneath as System Junk, different lens. This machine's biggest junk source = prime module for this user.

**Inventory-view template (design contract, user-requested from Pearcleaner):** every hub module (Uninstaller/Apps, Developer, Homebrew, Startup Items, Orphans, later Packages/Plugins/Lipo) renders same skeleton: sidebar entry, searchable list, size + status columns, inline row actions, bulk select bar. Central view, actionable in place. One template in SweepUI, N data sources.

### v1.1+ backlog

Duplicates finder, space lens (treemap), mail attachments, privacy cleaner (browser data), app updater, shredder, auto-cleanup on app trash (Sentinel pattern). Pearcleaner-inspired hub views (same inventory template): **Packages** (`pkgutil` receipts browser: list, files, uninstall-by-receipt; destructive so gated), **Plugins** (Internet Plug-Ins, PreferencePanes, app extensions inventory), **Lipo** (strip unused architecture slices; must ad-hoc re-sign after strip, careful with notarized apps), **File Search** (name search across system with size sort). Out of scope forever: malware scanning (liability, needs signature infrastructure we cannot maintain).

## 4. Permissions and onboarding

- **Full Disk Access** required for real cleaning, cannot be granted programmatically. Onboarding walks user to System Settings with live status check, re-check on app activation. FDA status modeled per capability as unknown/available/denied (heuristic, not boolean): multiple non-destructive probes + actual-operation errors; canary read failure ≠ proof of denial. Safe modules stay usable without FDA; manual System Settings fallback if deep link breaks; app + helper permission states tested independently.
- **Privileged helper** approval requested only at first system-level operation, never at install. macOS 13+ `SMAppService` flow, user approves in System Settings > Login Items.
- No sandbox. Cannot ship on Mac App Store, does not try.
- Distribution: two explicit build profiles. `local` (default): self-signed with stable local cert recipe (macos-native-tool skill) so TCC grants + helper approval survive rebuilds. `distributable` (defined now, built only if it ever leaves this machine): Developer ID, hardened runtime, inside-out signing incl. helper, notarize + staple, verify `codesign`/`spctl`/helper registration/FDA on clean account.

## 5. Design direction

Identity: **instrument, not toy**. Utility first, motion signals speed.

**Bar (user-set, 2026-08-31):** design must satisfy a lead-designer-at-Swiggy level reviewer (user's reference: Saptarshi). Measured, polished motion only; every animation must justify itself. Claude Design MCP used when connectable (down this session).

**Efficiency contract (user-set, no bloat):**
- Zero third-party dependencies. Apple frameworks + SF Symbols only; no Lottie, no bundled images/fonts.
- Motion = SwiftUI springs/Core Animation, no canvas-heavy effects; animations pause when window occluded.
- Budgets, CI-checked at M1/M5: release app binary < 12 MB, menubar idle < 50 MB RSS + <0.5% CPU at 2 s sampling, cold launch < 400 ms to first frame.
- Every dependency/asset addition requires a plan edit + justification line. Default answer = no.

- **Layout.** Two-tier grouped sidebar (Smart Scan + CLEAN/SPEED/APPS primary; Toolbox quieter, bottom, smaller type + tighter rows), large content pane. Hierarchy carried by weight + spacing, not color. Menubar popover = compact stat stack, one action row.
- **Type.** SF Pro throughout (platform face right choice here), SF Pro Display tight tracking for big numbers, SF Mono for paths + byte counts, tabular figures wherever data aligns. Oversized animated number (GB found, GB freed) = visual signature.
- **Color.** System materials (sidebar translucency, `.ultraThinMaterial` popover), graphite surfaces, single kinetic accent only for progress, results, scan sweep. Semantic colors (warning amber, danger red) reserved for safety tiers. Follows system light/dark.
- **Motion.** Three orchestrated moments, restraint everywhere else:
  1. Scan: radial sweep + counting number, spring-driven.
  2. Clean: byte counter rolls down to zero, ring collapses inward.
  3. Menubar gauge breathes under memory pressure.
  120 Hz aware, `Reduce Motion` respected, no particles, no confetti.
- Every screen designed against real data volumes (10k-row file lists), not toy fixtures. Large lists virtualized (NSTableView-backed representable if SwiftUI lists stutter).

## 6. Execution: phases, workstreams, agent assignment

Orchestration: Fable orchestrates, owns architecture-critical + security-critical code. Opus agents build core subsystems. Sonnet agents build well-specified modules in parallel worktrees. Haiku agents produce mechanical volume: rule catalogs, test fixtures, doc comments, localization strings.

Sequencing principle (Codex finding #13): safety infrastructure before destructive capability. Ship read-only scanner first, then trash-only execution, then direct deletion. Explicit destructive-release gate before every module that can mutate disk.

| Phase | Deliverable | Who |
|-------|------------|-----|
| P0 | Research: OSS landscape, API teardown, adversarial review | Sonnet x2 + Codex (DONE) |
| P1 | Scaffold: project, packages, build profiles, CI script, design tokens, `PrivacyInfo.xcprivacy` | Fable |
| P1 | Shared policy package (deny-by-default roots, denylist) + rule schema freeze | Fable |
| P1 | Security spike: XPC `setConnectionCodeSigningRequirement` prototype, tested vs unsigned/wrong-signed clients | Fable |
| P2 | SweepCore: scan engine, rules engine, WAL journal, `DeletionCoordinator`, identity revalidation | Opus |
| P2 | SweepSystem (stats) | Sonnet |
| P2 | SweepUninstall (matching + ownership evidence, read-only) | Sonnet |
| P2 | Rule catalog JSON (against frozen schema) + fake-junk fixture generator | Haiku |
| P3 | SweepUI design system + Smart Scan hero screen (read-only results first) | Fable/Opus |
| P3 | Inventory-view template component (SweepUI), then module screens: junk review, large files, uninstaller preview, startup, Homebrew, Developer | Sonnet x N |
| P3 | GATE 1: trash-only execution enabled after WAL recovery tests pass | Fable signs off |
| P4 | Menubar + popover; memory budget measured, split decision made | Opus |
| P4 | SweepHelper (XPC, SMAppService lifecycle state machine) | Opus (Fable reviews) |
| P4 | GATE 2: direct deletion for tier-`safe` after fault-injection suite passes | Fable signs off |
| P5 | Onboarding (FDA capability model), settings | Sonnet |
| P5 | Motion polish, screenshot-verified; Instruments pass | Fable |
| P6 | QA: review agents, rule-by-rule safety audit, real-machine trial | Opus review + Fable |

Milestones:

- **M1.** App launches, menubar live stats, idle memory measured vs 50 MB budget.
- **M2.** System Junk READ-ONLY end-to-end: scan, review UI, honest sizes. Zero deletion capability.
- **M3.** Gate 1 passed: trash-only cleaning with WAL + restore. Smart Scan hero. Design locked.
- **M4.** Helper live, gate 2 passed (safe-tier direct deletion), maintenance + memory + Homebrew.
- **M5.** Onboarding, polish, budgets met, rule-by-rule safety audit passed (P6 workstream, M5 exit criterion) → full capability enabled.

Verification rules, every agent:

- `xcodebuild build test` must pass before any merge back.
- UI work verified by screenshot (macos-native-tool harness), not assertion.
- Deletion code tested only against fixture trees on disposable APFS disk images until audit signs off. Fault-injection suite required: symlink swaps mid-operation, hardlinks, nested mounts, case/Unicode aliases, concurrent renames, ENOSPC during journaling, crash-after-rename recovery, volume unmount mid-delete, read-only media, malicious XPC clients (unsigned, wrong signature, wrong UID). Property/fuzz tests for rule resolution.
- First real-machine runs trash-only mode.
- This machine's known hogs (Xcode junk, Claude vm_bundles, leaked code-sign clones per disk-cleanup skill) = acceptance fixtures for junk scanner.

## 7. Risks

- **Wrong deletion catastrophic.** Mitigated: deny-by-default policy, tiers, identity revalidation, WAL + quarantine, trash-first, two destructive-release gates, fault-injection suite, M5 audit. This risk owns architecture.
- **Adversarial review incorporated.** Codex review 2026-08-31, 23 findings (4 critical), all accepted into sections above: helper auth spike moved to P1, Empty Trash de-automated, WAL transaction semantics, deny-by-default authorization, ownership evidence for uninstall, cloud-file protection, process preflight, catalog trust model, result semantics, helper lifecycle, resequenced gates, fault-injection tests, dual build profiles, VolumePolicy, typed command adapters, DeletionCoordinator ownership, startup-items scope-down, FDA-as-heuristic, reclaim reporting via capacity deltas, lsregister + fake purgeable-free dropped, menubar split decision gate.
- **SwiftUI perf on huge lists.** Fallback planned (AppKit representable).
- **FDA onboarding friction.** One UX moment deciding whether app feels premium.
- **"Free RAM" mostly placebo on modern macOS.** Differentiate by honesty; pending API research confirms exactly what purge achieves.
- **macOS 26 API drift.** Pin to documented APIs, no private API use.

---

## Appendix A: verified junk path catalog (seed for the rules JSON)

| Target | Path | Tier |
|--------|------|------|
| User caches | `~/Library/Caches` | safe (per-dir rules) |
| Sandboxed app caches | `~/Library/Containers/<id>/Data/Library/Caches` | safe |
| Logs | `~/Library/Logs`, `/Library/Logs`, `/var/log` | safe/caution |
| Unified logs | `/var/db/diagnostics`, `/var/db/uuidtext` | expert, via `log erase` only, never raw delete |
| Xcode | `~/Library/Developer/Xcode/{DerivedData,Archives}`, `iOS DeviceSupport` | safe/caution |
| Simulators | `xcrun simctl delete unavailable` (never raw-delete CoreSimulator/Devices) | safe |
| Homebrew | `brew cleanup --prune=all` (cache at `~/Library/Caches/Homebrew`) | safe |
| npm / pnpm / pip / cargo | `~/.npm/_cacache`, `pnpm store path`, `~/Library/Caches/pip`, `~/.cargo/registry` | safe |
| Docker | `~/Library/Containers/com.docker.docker/.../Docker.raw` (sparse: size by allocated blocks) | caution |
| Browser caches | Chrome `~/Library/Caches/Google/Chrome` + profile `Cache`; Firefox `~/Library/Caches/Firefox/Profiles/*/cache2`; Safari `~/Library/Containers/com.apple.Safari/Data/Library/Caches` (TCC) | safe |
| iOS backups | `~/Library/Application Support/MobileSync/Backup` | caution |
| Trash | `~/.Trash`, `/Volumes/*/.Trashes/<uid>` | safe |
| Mail attachments | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` (copies only, needs FDA; never touch `~/Library/Mail/V*`) | caution |
| Crash reports | `~/Library/Logs/DiagnosticReports`, `/Library/Logs/DiagnosticReports` | safe |
| APFS snapshots | `tmutil listlocalsnapshots` / `thinlocalsnapshots`; surface, never silent-delete | caution |
| Code-sign clones | `$DARWIN_USER_TEMP_DIR/../X/*.code_sign_clone` (code-driven detector, not glob: per-item app-not-running + >10 min age checks; CoW-honest sizing) | safe |

## Appendix B: API reference (verified by research, exceptions marked)

- Enumeration: `getattrlistbulk` (Apple-recommended balance) or `fts_read` (fastest; speed levers `FTS_NOSTAT` + `FTS_XDEV`); `FileManager.enumerator` with prefetched keys acceptable v1. On-disk size via `totalFileAllocatedSizeKey` (physical blocks); `totalFileSizeKey` logical. APFS clones share blocks, logical sums can overstate real cost 10-100x; clone families detectable via `getattrlist` `ATTR_CMNEXT_CLONEID`.
- Purgeable space: Capacity = Available + (Used - Purgeable); estimate via `volumeAvailableCapacityForImportantUsageKey` vs `volumeAvailableCapacityKey`. Reclaim = OS job (`deleted(8)`); accounting known-unreliable, present as estimate. Both capacity keys "required reason" APIs: declare in `PrivacyInfo.xcprivacy` at P1.
- Stats: CPU `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas per core; RAM `host_statistics64` (page counts x `host_page_size`); network `getifaddrs` filtered to `AF_LINK`, `if_data.ifi_ibytes/obytes` deltas (counters can wrap at 4 GB, handle it); battery `IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` IORegistry for cycles/health (`IOPMCopyBatteryInfo` legacy, do not use); disk `statfs` + volume URL keys. None need entitlement. SMC temps/fans need privileged helper (Stats ships one); defer sensors to backlog.
- FDA detection: probe protected canary (`~/Library/Safari/CloudTabs.db`), deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, re-check on app activation.
- Helper: `SMAppService.daemon(plistName:)`, plist must live inside app bundle at `Contents/Library/LaunchDaemons` (never copied to `/Library/LaunchDaemons` manually). `register()` triggers user approval, can fail if already registered or approval denied; poll `status` (`.requiresApproval` etc.); audit with `sudo sfltool dumpbtm`. Approval survives rebuilds only with stable signing identity (self-sign recipe). XPC caller validation VERIFIED (Codex review): `NSXPCListener.setConnectionCodeSigningRequirement(_:)`, listener-level requirement rejecting peers before delegate accepts — https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:). P1 spike proves it.
- Maintenance commands (typed adapters, never shell): `dscacheutil -flushcache` + `killall -HUP mDNSResponder`, `mdutil -E`, `tmutil thinlocalsnapshots`. `lsregister` DROPPED: internal undocumented tool.