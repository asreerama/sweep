# Helper-side scanning: design and verdict

Question: should `SweepHelper` walk the filesystem for Smart Scan / System Junk (not just run
the three fixed maintenance commands it runs today), and what would that buy?

## 1. Verdict

**Later, not now, and gated separately from the work already in flight.** Helper-side scanning
is a real but narrow *coverage* play — it unlocks a handful of root-owned system paths
(`/Library/Caches`, `/var/log`) and, if ever needed, other local users' home directories — not a
speed play: root does not make `getattrlistbulk`/`fts_read` faster, and the scan speed work
already landing (`FileManagerVolumeWalker`'s prefetched-key enumeration, `ScanWorkerPool`'s
parallel root walks) runs exactly as fast in-process as it would inside a root daemon. Building
it now would also hand a brand-new "walk arbitrary parts of the filesystem as root and stream
results back" capability to a helper whose entire adversarial-review history (`GeneratedHelperTrust`,
the P1 code-signing spike, Gate `HELPER: OPEN`) was scoped to three closed-enum commands that
touch no user files at all (`flushDNS`, `reindexSpotlight`, `thinSnapshots` —
`Packages/SweepPolicy/Sources/SweepPolicy/HelperProtocol.swift:13-21`). That is a materially
different threat model and deserves its own review pass, not a rider on Gate 2. Revisit after
Gate 2 (direct deletion, `BUILDLOG.md:24,29,66-67`, currently `gate2Open=false` with the
fault-injection suite unwritten) and M5's rule-by-rule audit ship — see §5 for the phased plan.

## 2. What it buys

**Coverage, quantified against what exists today.**

`Packages/SweepPolicy/Sources/SweepPolicy/Policy.swift:16-29` already carves out
`.systemCaches` and `.systemLogs` as `OperationRoot` cases marked `// helper-only`, resolving to
`/Library/Caches` (`Policy.swift:159-160`) and `/Library/Logs` + `/var/log`
(`Policy.swift:161-165`). `Sources/SweepApp/Scan/ScanService.swift:294-300` is explicit about why
the unprivileged scan never walks them: `buildUnits` only walks rules whose action isn't
`.commandPreview`, and the comment says plainly "That also keeps the helper-only system roots
(`/Library/Caches`, `/var/log`) out of an unprivileged read-only scan." So today's scan simply
never attempts these roots — it doesn't fail on them, it skips them by construction.

That skip is mostly a **POSIX-permission** gap, not a TCC gap: subdirectories of `/Library/Caches`
and log files under `/var/log` are frequently owned by `root` or by other daemons' UIDs with
restrictive modes, so an unprivileged read gets `EACCES` regardless of Full Disk Access. A root
helper genuinely unlocks these — `st_uid`/mode checks are bypassed for `uid 0`, no FDA involved.
The same logic would unlock other local users' `~/Library/Caches` and `~/Library/Logs` on a
multi-user Mac (home directories are typically mode `700`), though nothing in `SweepPolicy`
models "another user's home" as a root today — it would be new vocabulary, not a flag flip.

**What it does NOT unlock**, per the task's hard facts: `/var/db/diagnostics` and
`/var/db/uuidtext` (unified logs, PLAN Appendix A: "expert, via `log erase` only, never raw
delete" regardless of privilege), and — critically — anything TCC actually gates: other users'
Downloads/Documents/Desktop, removable/external volume contents, Photos, Mail. Root does not
bypass TCC. The helper's own binary identity would need its own Full Disk Access grant in System
Settings for those, exactly like the app does today (`PLAN.md:121`, `Packages/SweepSystem/Sources/SweepSystem/Capabilities.swift:82-95`).
Since Sweep's hard denylist already excludes Documents/Desktop/Pictures/iCloud/CloudStorage/
Photos/Mail from every scan regardless of tier or privilege (`Policy.swift:31-42`), this isn't
even a capability the design should chase — it's out of scope by policy, not by permission.

**Speed: none, and be explicit about why.** The current walker already does the two things that
make a filesystem walk fast: `FileManagerVolumeWalker` prefetches resource keys in one batch per
directory (`Packages/SweepCore/Sources/SweepCore/Scan/VolumeWalker.swift:95-103`, "Prefetched in
a single `getattrlistbulk` batch per directory by Foundation"), and `ScanService.run` submits
every root's walk up front so `ScanWorkerPool`'s two dedicated threads keep a second walk
pre-running while the first is consumed (`Sources/SweepApp/Scan/ScanService.swift:156-168`,
`Packages/SweepCore/Sources/SweepCore/Scan/ScanBackpressure.swift:171-227`, worker count pinned
to 2: "directory walks are I/O-bound and a third concurrent walk on the same device buys nothing
but contention"). None of that gets faster inside a root process — same syscalls, same disk,
same page cache. Moving the *existing* roots into the helper would only add one XPC hop per batch
for zero benefit. The only honest speed story is: helper scanning **adds** roots (more files
examined, more wall-clock), it never makes the roots already scanned faster.

**FDA-prompt consolidation — real, but narrower than it sounds.** Today FDA is granted once, to
Sweep.app, per macOS user account (`CapabilityStore`/`FullDiskAccessProbe`,
`Packages/SweepSystem/Sources/SweepSystem/Capabilities.swift`). On a single-user machine (this
one) that's already one grant, so a helper adds nothing. The genuine win is multi-user: FDA for
a `LaunchDaemon` is a single systemwide grant an admin adds once in System Settings, versus every
additional user having to grant FDA to Sweep.app under their own login session before Sweep can
see anything of theirs. That only matters once "other users' caches" is an actual feature (see
Phase 2, §5) — for the coverage this design can ship first (`/Library/Caches`, `/var/log`), no
FDA is involved either way, so there is no consolidation to bank yet.

## 3. Design sketch

**XPC surface.** `SweepHelperXPCProtocol` today is two methods, `Data` in/out
(`Packages/SweepPolicy/Sources/SweepPolicy/HelperXPCProtocol.swift:18-29`). Scanning needs a third
shape entirely: a long-running, streamed, cancellable operation, which a single `Data`-in/
`Data`-out reply cannot express. `NSXPCConnection` supports this the same way any bidirectional
XPC service does — the app additionally *exports* a small client interface
(`SweepHelperScanClientProtocol`, `func receiveBatch(_ data: Data, reply: @escaping () -> Void)`)
on its side of the connection, and the helper's new `startScan(_ requestData: Data, reply: @escaping (Data) -> Void)`
call (immediate ack: scan accepted/rejected + a scan id) is followed by the helper calling back
into that client interface with batches as `SweepCore.ScanEvent`s accumulate. `cancelScan(_ scanID: Data, reply: @escaping (Data) -> Void)`
mirrors `ScanEngine.cancel(scanID:)` (`Packages/SweepCore/Sources/SweepCore/Scan/ScanEngine.swift:87-89`)
exactly — same lookup-by-`UUID`, same cooperative-cancellation contract.

**Backpressure over the wire, not just in-process.** `ScanEventBuffer`'s watermark/semaphore
design (`Packages/SweepCore/Sources/SweepCore/Scan/ScanBackpressure.swift:33-134`) already solves
"never let a fast producer outrun a slow consumer" for the in-process case — a walk thread blocks
in `push` until the consumer catches up. Over XPC the same shape carries over almost for free:
`receiveBatch`'s `reply` closure is the semaphore signal. The helper's scan loop sends one batch
(N `ScanEvent`s, JSON- or property-list-encoded — batch size should track the existing
`eventWatermark: 4096` used by `ScanService.run`, `Sources/SweepApp/Scan/ScanService.swift:127`)
and blocks the next `push` until `receiveBatch`'s reply fires, exactly reproducing today's
watermark semantics one XPC round trip per batch instead of one function call per batch.
**Never send one `ScanEvent` per XPC call** — see §4 for the order-of-magnitude cost of getting
this wrong.

**Composition with `ScanEngine`/`VolumeWalker`.** The helper should host the *same*
`SweepCore.ScanEngine` and `FileManagerVolumeWalker` (or the `fts_read` backend once it lands
behind the same `VolumeWalker` protocol, `VolumeWalker.swift:72-76`) that the app already uses —
not a second walker implementation. `SweepHelper/Sources/SweepHelper/main.swift:1-3` currently
imports only `Foundation`, `Security`, `SweepPolicy`; this adds a `SweepCore` dependency to the
helper target, nothing else. The helper constructs `ScanRequest`s itself, from roots it resolves
itself — never a path the app sends across the wire, following the same rule PLAN §2 already
states for maintenance ops ("helper derives paths from validated UIDs/bundle IDs, never accepts
caller-selected absolute paths"). Concretely: a new, small, closed enum —
`PrivilegedScanRoot { case systemCaches, systemLogs }` today, `case otherUserHome(uid:)` only if
Phase 2 ever ships — resolved helper-side through the same `SweepPolicy.resolvedRoots`-shaped
logic `Policy.swift:171-189` already uses, so a scan request on the wire names a *symbolic* root
(an enum case, encoded the same closed-by-construction way `MaintenanceOperation` is,
`HelperProtocol.swift:13-57`), never a string path.

**Read-only enforcement.** The helper's scan handler must be reachable only from code that cannot
also reach a deletion path. Today that's trivially true: nothing in `SweepHelper/Sources/SweepHelper/`
links `DeletionCoordinator` or any mutating type — `MaintenanceExecutor.swift` only ever calls
`HelperProcessRunner.run` on the three fixed, argv-array commands from `MaintenanceCommandPlan`
(`HelperProtocol.swift:173-240`). Keep it that way by construction: the scan feature's helper-side
module should not import whatever package eventually hosts `DeletionCoordinator`, so "the helper
can only read" is enforced by the dependency graph, not by code review discipline alone. On the
policy side, the helper still runs every candidate path through `SweepPolicy`'s protected-area
denylist before it's ever emitted (`isDeniedLexically`, `Policy.swift:91-103`, plus the resolved-
identity check `protectedAreaViolation`, `Authorization.swift:318-343`) — the walker already does
this today via `WalkOptions.honorsPolicyDenylist` (`VolumeWalker.swift:46,135-139`), so hosting it
in the helper changes nothing about that check, it just means the check runs as root instead of
as the logged-in user (see §4 for why that raises the stakes of a bug there, not the design of
the check itself).

**FDA grant flow for the helper.** A `LaunchDaemon` has no window and cannot pop the interactive
TCC consent sheet the app gets by attempting a protected read. The user has to add the helper's
installed binary to System Settings ▸ Privacy & Security ▸ Full Disk Access manually (the "+"
file picker), which only matters once Phase 2's TCC-gated roots exist — Phase 1's roots
(`/Library/Caches`, `/var/log`) need no FDA at all (§2). When it does matter, reuse the existing
deep-link (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, PLAN
Appendix B) with copy telling the user which binary to add, and reuse `FullDiskAccessProbing`
(`Capabilities.swift:76-80`) helper-side: the helper runs the same three canary reads
(`Capabilities.swift:96-111`) inside a new lightweight `helperCapabilities(reply:)` XPC call, and
`CapabilityStore` folds the result into a second `SweepCapability` case using the same pure
`CapabilityAggregator.status(from:)` (`Capabilities.swift:63-69`) it already uses for the app's
own probe — no new aggregation logic, just a second probe source.

## 4. Risks and costs

- **TCC is unchanged by privilege.** Root still gets `EPERM`/`EACCES` on removable volumes and
  per-user Documents/Downloads/Desktop (task's verified hard fact). The design above never asks
  for that coverage — Phase 1's roots are chosen specifically because they're a POSIX gap, not a
  TCC one. If Phase 2 ever adds a TCC-gated root, budget for the helper needing its own separate
  FDA grant, not inheriting the app's.
- **The helper loses its free safety net.** Every unprivileged scan today gets a second,
  OS-enforced backstop for free: even if `SweepPolicy`'s denylist had a bug, the kernel's own
  permission check on `~/Documents` etc. would still deny an unprivileged reader in most
  cross-user cases. A root process has no such backstop — `SweepPolicy`'s resolved-identity
  denylist (`Authorization.swift:318-343`) becomes the *only* thing standing between a root
  scanner and a protected area. This is a real increase in blast radius for a single logic bug,
  not just a talking point, and is the strongest argument for treating this as its own gate
  rather than folding it into Gate 2's existing fault-injection matrix.
- **IPC overhead vs. in-process, order of magnitude.** An `NSXPCConnection` round trip for a
  small payload is roughly tens of microseconds to low single-digit milliseconds depending on
  payload size and `NSSecureCoding`/JSON marshaling — call it ~100 μs–1 ms per call. Batched at
  the existing `eventWatermark: 4096` granularity (`ScanService.swift:127`), that's amortized to
  a few tens of nanoseconds per entry: noise next to the walk itself. Sent one `ScanEvent` per
  XPC call instead, the same 100 μs–1 ms tax applies *per file*: a 2-million-file walk (this
  machine's rough order per the disk-cleanup skill's findings) would add minutes to tens of
  minutes of pure IPC overhead on top of a walk that otherwise finishes in seconds. Batching is
  not an optimization here, it's the difference between shippable and not.
- **New attack surface, new failure mode.** The existing three `MaintenanceOperation` cases
  return no filesystem content at all — worst case, a malicious caller flushes DNS or thins a
  snapshot. A scan surface returns file names, sizes, and timestamps for parts of the filesystem
  an unprivileged process could not otherwise see — a new metadata-disclosure question
  (`HelperListenerDelegate`'s code-signing + console-UID checks, `HelperListenerDelegate.swift:23-27`,
  and `HelperService.perform`'s per-call re-check, `HelperService.swift:88-93`, guard *who* can
  call, but nothing today limits *what filesystem metadata* a caller can extract — because today
  there's none to extract). The scan-root enum must stay as closed and server-resolved as
  `MaintenanceOperation` already is, with no path for a caller to widen it.
- **Gate discipline.** PLAN §6's sequencing principle is "safety infrastructure before
  destructive capability. Ship read-only scanner first, then trash-only execution, then direct
  deletion" (`PLAN.md:173`). Helper-side scanning is read-only, so it doesn't violate the letter
  of that ordering — but the helper's own security spike was scoped and adversarially reviewed
  (P1, `PLAN.md:69,180`, Gate `HELPER: OPEN` in `BUILDLOG.md:18`) against three commands that
  touch no user files. Broadening the helper's job to "walk the filesystem as root" is a new
  spike, not a checkbox on an old one, and should get a named gate and its own Codex pass rather
  than ride in on Gate 2's fault-injection suite (which is about deletion correctness, not scan
  disclosure).

## 5. Recommendation and effort

**Now:** nothing. Gate 2 (direct-delete safe-tier, fault-injection suite) and Gate U (uninstaller
signed-evidence/rollback) are both still open (`BUILDLOG.md:24,29,66-67`) and are the review
budget's actual priority; a new helper capability competes with both for the same Codex/Fable
review cycles that are already stretched across two open gates.

**Phase 1 (after Gate 2 and M5's rule-by-rule audit ship):** a minimal spike, scoped exactly like
the original P1 helper spike was —
- Extend `SweepHelperXPCProtocol` with `startScan`/`cancelScan` + an exported client callback
  interface (§3). ~1 day.
- Add `SweepCore` as a helper dependency; host `ScanEngine` + `FileManagerVolumeWalker` against a
  new closed `PrivilegedScanRoot { case systemCaches, systemLogs }`. ~1 day.
- Batch-over-XPC backpressure bridging `ScanEventBuffer`'s existing semaphore to `receiveBatch`'s
  reply closure (§3–§4). ~1 day.
- Helper-side capability probe reuse (§3) + UI wiring to show the two new roots as an additional,
  clearly-labeled section in System Junk (not silently merged into the existing safe-tier caches,
  since they're root-owned and higher-caution by nature). ~1 day.
- Dedicated adversarial review pass (Codex + Fable) against the new scan surface specifically —
  malformed scan requests, cancellation-on-connection-drop (no per-connection scan registry
  exists today; §3 needs one so a dropped connection cancels its walk instead of leaking a
  root-owned thread), oversized batches, root-enum widening attempts. ~2 days, matching the
  original P1 spike's scale.

Total: roughly one week for one Opus/Fable-reviewed agent, plus its own gate sign-off — call it
**Gate H2**, separate from Gate 2/Gate U, named so it never gets silently bundled into either.

**Phase 2 (only on an actual multi-user request):** other users' home directories. Bigger scope —
new consent UX (an admin is reading another human's account, even "just" caches), `dscl`/
OpenDirectory enumeration of local accounts, and the FDA-grant story from §2 finally pays off.
Hold until there is a real user, since this machine is single-user and Phase 2 has no current
justification.
