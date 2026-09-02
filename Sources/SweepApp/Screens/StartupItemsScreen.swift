import AppKit
import ServiceManagement
import SweepUI
import SwiftUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/StartupItemsLogicTests.swift)

/// Where one `StartupItemRow` was found. Login Items in the System-Settings sense (anything
/// registered via `SMAppService` by an app other than Sweep) have no public enumeration API —
/// PLAN §3 explicitly rules out the deprecated `LSSharedFileList` route — so this module's
/// inventory is exactly the three plist directories below, plus a best-effort read of Sweep's
/// own `SMAppService` registration (see `SMAppServiceInventory`). That gap is why the module also
/// ships the System Settings deep link.
enum StartupItemSource: String, CaseIterable, Sendable, Hashable {
    case userLaunchAgent
    case systemLaunchAgent
    case systemLaunchDaemon

    var title: String {
        switch self {
        case .userLaunchAgent: "Launch Agents (This User)"
        case .systemLaunchAgent: "Launch Agents (All Users)"
        case .systemLaunchDaemon: "Launch Daemons"
        }
    }

    var symbol: String {
        switch self {
        case .userLaunchAgent, .systemLaunchAgent: "gearshape"
        case .systemLaunchDaemon: "gearshape.2"
        }
    }

    func directory(home: URL) -> URL {
        switch self {
        case .userLaunchAgent: home.appending(path: "Library/LaunchAgents")
        case .systemLaunchAgent: URL(fileURLWithPath: "/Library/LaunchAgents")
        case .systemLaunchDaemon: URL(fileURLWithPath: "/Library/LaunchDaemons")
        }
    }
}

/// One parsed launchd plist. `id` is the plist's own path, which doubles as the reveal target.
struct StartupItemRow: Identifiable, Hashable {
    let id: String
    let label: String
    let programPath: String?
    let source: StartupItemSource
    let runAtLoad: Bool
    let binaryExists: Bool

    /// A label with no program that actually exists on disk: the item will fail to launch.
    /// `programPath == nil` (a plist with neither `Program` nor `ProgramArguments`) is not itself
    /// flagged broken — that shape is unusual but not invalid, and this module has no way to
    /// know what launchd would have done with it.
    var isBroken: Bool { programPath != nil && !binaryExists }
}

/// Parses one launchd-style plist (`Label`, `Program`/`ProgramArguments`, `RunAtLoad`) into a row.
/// Pure: the disk check is an injected closure so this is testable without touching the
/// filesystem, and the default matches what `StartupItemsScanner` uses for a real scan.
enum StartupItemParser {
    static func parse(
        plistData: Data,
        path: String,
        source: StartupItemSource,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> StartupItemRow? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
            let label = plist["Label"] as? String
        else { return nil }

        let program = plist["Program"] as? String
        let arguments = plist["ProgramArguments"] as? [String]
        let programPath = program ?? arguments?.first
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let exists = programPath.map(fileExists) ?? false

        return StartupItemRow(
            id: path,
            label: label,
            programPath: programPath,
            source: source,
            runAtLoad: runAtLoad,
            binaryExists: exists
        )
    }
}

/// Read-only directory listing over the three launchd plist roots. Every failure (unreadable
/// directory, unparsable plist) is dropped silently rather than surfaced: a system-owned
/// `/Library/LaunchDaemons` entry this process cannot read is routine, not an error worth a
/// footnote the way a scan's skipped roots are.
enum StartupItemsScanner {
    static func scanDirectory(
        _ url: URL,
        source: StartupItemSource,
        fileManager: FileManager = .default
    ) -> [StartupItemRow] {
        guard let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "plist" }
            .compactMap { fileURL -> StartupItemRow? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return StartupItemParser.parse(plistData: data, path: fileURL.path, source: source)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func scanAll(home: URL, fileManager: FileManager = .default) -> [StartupItemRow] {
        StartupItemSource.allCases.flatMap { source in
            scanDirectory(source.directory(home: home), source: source, fileManager: fileManager)
        }
    }
}

/// One `SMAppService`-visible entry: Sweep's own login/agent/daemon registration, read where the
/// public API actually exposes it (PLAN §3: "SMAppService-visible items where readable"). There
/// is no public call that lists *other* apps' registrations, which is the whole reason this
/// module also ships a System Settings deep link rather than pretending to be complete.
struct SMAppServiceRow: Identifiable, Hashable {
    let id: String
    let label: String
    let statusDescription: String
}

enum SMAppServiceInventory {
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    /// Sweep's own launch-at-login registration, if any. Reflects reality even before Sweep ever
    /// registers one: `SMAppService.mainApp.status` is `.notRegistered` until it does.
    static func mainAppRow(bundle: Bundle = .main) -> SMAppServiceRow {
        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleExecutable"] as? String)
            ?? "Sweep"
        return SMAppServiceRow(
            id: "main-app",
            label: "\(name) (launch at login)",
            statusDescription: describe(SMAppService.mainApp.status)
        )
    }

    /// Helper agents/daemons bundled under `Contents/Library/{LaunchAgents,LaunchDaemons}` — per
    /// PLAN Appendix B, the only place a plist may live for `SMAppService` to see it. Sweep ships
    /// no helper yet (that lands at P4), so this is normally empty; the mechanism exists so a row
    /// appears the moment one does, with no UI change needed then.
    static func bundledServiceRows(bundle: Bundle = .main) -> [SMAppServiceRow] {
        let subdirectories: [(path: String, isDaemon: Bool)] = [
            ("Contents/Library/LaunchAgents", false),
            ("Contents/Library/LaunchDaemons", true),
        ]
        var rows: [SMAppServiceRow] = []
        for entry in subdirectories {
            let directory = bundle.bundleURL.appending(path: entry.path)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let service = entry.isDaemon ? SMAppService.daemon(plistName: name) : SMAppService.agent(plistName: name)
                rows.append(SMAppServiceRow(id: name, label: name, statusDescription: describe(service.status)))
            }
        }
        return rows
    }

    static func allRows(bundle: Bundle = .main) -> [SMAppServiceRow] {
        [mainAppRow(bundle: bundle)] + bundledServiceRows(bundle: bundle)
    }
}

// MARK: - Screen

/// Startup Items (module 6, PLAN §3): read-only inventory, reveal, and a deep link to the
/// System Settings pane that can actually manage them. No enable/disable toggle — PLAN restricts
/// that to modules with a documented public API to back it, and none exists here yet.
struct StartupItemsScreen: View {
    @State private var rows: [StartupItemRow] = []
    @State private var serviceRows: [SMAppServiceRow] = []
    @State private var hasLoaded = false

    private var groupedRows: [StartupItemSource: [StartupItemRow]] {
        Dictionary(grouping: rows, by: \.source)
    }

    private var brokenCount: Int { rows.filter(\.isBroken).count }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Destination.startupItems.title, subtitle: Destination.startupItems.subtitle) {
                Button("Manage in System Settings") { openSystemSettings() }
                    .buttonStyle(.sweepQuiet)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task {
            let home = ScanEnvironment.resolve().home
            let result = await Task.detached(priority: .utility) {
                (StartupItemsScanner.scanAll(home: home), SMAppServiceInventory.allRows())
            }.value
            rows = result.0
            serviceRows = result.1
            hasLoaded = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded {
            InventoryEmptyState(symbol: "power", title: "Reading startup items\u{2026}")
        } else if rows.isEmpty && serviceRows.isEmpty {
            InventoryEmptyState(
                symbol: "checkmark.circle",
                title: "Nothing readable here",
                message: "No login items, launch agents or launch daemons were readable on this Mac."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s5) {
                    if !serviceRows.isEmpty {
                        serviceSection
                    }
                    ForEach(StartupItemSource.allCases, id: \.self) { source in
                        if let sourceRows = groupedRows[source], !sourceRows.isEmpty {
                            section(for: source, rows: sourceRows)
                        }
                    }
                }
                .padding(SweepTokens.s5)
            }
        }
    }

    private var serviceSection: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("This App (SMAppService)")
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s2)

                ForEach(Array(serviceRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    HStack(spacing: SweepTokens.s3 - 2) {
                        Image(systemName: "power.circle")
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, alignment: .center)
                        Text(row.label)
                            .font(SweepFont.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: SweepTokens.s3)
                        Text(row.statusDescription)
                            .font(SweepFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, SweepTokens.s3 - 2)
                    .frame(height: SweepTokens.inventoryRowHeight)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    private func section(for source: StartupItemSource, rows: [StartupItemRow]) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SweepTokens.s2) {
                    Text(source.title)
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.secondary)
                    Text(SweepFormat.itemCount(rows.count))
                        .font(SweepFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s2)

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    StartupItemRowView(row: row) { reveal(row) }
                        .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    private var footer: some View {
        Group {
            if hasLoaded, !rows.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Footnote(footerText, symbol: brokenCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                        Spacer()
                    }
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.vertical, SweepTokens.s3)
                }
                .background(.bar)
            }
        }
    }

    private var footerText: String {
        if brokenCount > 0 {
            let noun = brokenCount == 1 ? "item points" : "items point"
            return "\(brokenCount) \(noun) to a program that no longer exists."
        }
        return "\(SweepFormat.count(rows.count)) items read. Nothing here can be enabled or disabled from Sweep yet."
    }

    // MARK: - Actions

    private func reveal(_ row: StartupItemRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)])
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One launch agent/daemon row: label, program path (SF Mono, middle-truncated), a broken flag,
/// and a reveal button. Not built on the shared `InventoryRow` — that component's size column has
/// no equivalent here (there is no byte count to show), so this reuses only the design tokens.
private struct StartupItemRowView: View {
    let row: StartupItemRow
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: row.source.symbol)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .center)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.label)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.programPath ?? "No program path")
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SweepTokens.s3)
            if row.isBroken {
                BrokenBadge()
            }
            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(row.label) in Finder")
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .frame(height: SweepTokens.inventoryRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Flags a launch item whose program no longer exists on disk. Deliberately not `TierBadge`:
/// that component's vocabulary is deletion-safety tiers (Safe/Caution/Expert), and a broken
/// program reference is a different concept — reusing the badge would read as this app judging
/// the item's safety when it is only reporting a fact.
private struct BrokenBadge: View {
    var body: some View {
        Text("BROKEN")
            .font(SweepFont.badge)
            .tracking(0.5)
            .foregroundStyle(SweepTokens.tierExpert)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SweepTokens.tierExpert.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(SweepTokens.tierExpert.opacity(0.28), lineWidth: 0.5)
            )
            .accessibilityLabel("Broken: program not found")
    }
}
