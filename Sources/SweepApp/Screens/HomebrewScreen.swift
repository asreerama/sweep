import SwiftUI
import SweepUI

/// Homebrew (module 9, PLAN §3): a typed GUI over `brew` — installed formulae/casks with sizes,
/// outdated packages, cache size, and preview-first maintenance actions.
///
/// Read-mostly by design: every mutation (`cleanup`, `autoremove`, per-item `upgrade`) goes
/// through `HomebrewModel`'s preview-then-confirm flow, never runs on first tap, and streams its
/// raw output into the console disclosure at the bottom rather than a silent success/fail toast.
struct HomebrewScreen: View {
    @State private var model = HomebrewModel()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.homebrew.title,
                subtitle: Destination.homebrew.subtitle
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if model.loadState == .loaded {
                        SweepSearchField(text: $query, prompt: "Filter packages")
                            .frame(width: 200)
                    }
                    Button("Refresh") { Task { await model.refresh() } }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.loadState == .loading)
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Read-mostly listing (PLAN's own vocabulary for this module) auto-loads once, the same
        // way `StartupItemsScreen`/`MemoryScreen` do — unlike Developer's disk walk, this is a
        // handful of fast `brew` metadata reads plus directory sizing, not a scan worth gating
        // behind an explicit first click.
        .task { await model.refresh() }
        .sheet(item: Binding(
            get: { model.pendingAction },
            set: { newValue in if newValue == nil { model.cancelPendingAction() } }
        )) { action in
            BrewCommandPreviewSheet(
                action: action,
                isReady: model.isPendingActionReady,
                onCancel: { model.cancelPendingAction() },
                onConfirm: { model.confirmPendingAction() }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            InventoryEmptyState(symbol: "mug", title: "Checking Homebrew\u{2026}")
        case .unavailable:
            InventoryEmptyState(
                symbol: "mug",
                title: "Homebrew isn\u{2019}t installed",
                message: "Sweep looked for it at \(BrewExecutable.appleSiliconPath) and "
                    + "\(BrewExecutable.intelPath). Install it from brew.sh to manage formulae, "
                    + "casks and caches from here."
            )
        case .failed(let message):
            InventoryEmptyState(symbol: "exclamationmark.triangle", title: "Couldn\u{2019}t read Homebrew", message: message)
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SweepTokens.s5) {
                summarySection
                if !model.snapshot.outdated.isEmpty {
                    outdatedSection
                }
                installedSection
                maintenanceSection
                if !model.consoleLog.isEmpty {
                    consoleSection
                }
            }
            .padding(SweepTokens.s5)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        SectionCard {
            HStack(spacing: 0) {
                statTile(title: "Formulae", value: SweepFormat.count(model.snapshot.formulae.count))
                Divider().frame(height: 32)
                statTile(title: "Casks", value: SweepFormat.count(model.snapshot.casks.count))
                Divider().frame(height: 32)
                statTile(
                    title: "Outdated",
                    value: SweepFormat.count(model.snapshot.outdated.count),
                    tint: model.snapshot.outdated.isEmpty ? nil : SweepTokens.accent
                )
                Divider().frame(height: 32)
                statTile(title: "Cache", value: model.snapshot.cache.map { SweepFormat.bytes($0.sizeBytes) } ?? "\u{2013}")
            }
            .padding(SweepTokens.s4)
        }
    }

    private func statTile(title: String, value: String, tint: Color? = nil) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? SweepTokens.heroInk)
            Text(title.uppercased())
                .font(SweepFont.badge)
                .tracking(0.5)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var outdatedSection: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            Text("Outdated")
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
            SectionCard {
                ForEach(Array(model.snapshot.outdated.enumerated()), id: \.element.id) { index, package in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    packageRow(package)
                        .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
        }
    }

    private var filteredPackages: [BrewPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let base = model.snapshot.packages
        let matched = trimmed.isEmpty
            ? base
            : base.filter { $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            HStack(spacing: SweepTokens.s2) {
                Text("Installed")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
                Text(SweepFormat.itemCount(filteredPackages.count))
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
            }
            if filteredPackages.isEmpty {
                Text(query.isEmpty ? "Nothing installed via Homebrew." : "No matches.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, SweepTokens.s2)
            } else {
                SectionCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredPackages.enumerated()), id: \.element.id) { index, package in
                            if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                            packageRow(package)
                                .padding(.horizontal, SweepTokens.s3 - 2)
                        }
                    }
                }
            }
        }
    }

    private func packageRow(_ package: BrewPackage) -> some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: package.isCask ? "app.dashed" : "shippingbox")
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .center)
            VStack(alignment: .leading, spacing: 0) {
                Text(package.name)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(package.installedVersion ?? (package.isCask ? "cask" : "formula"))
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: SweepTokens.s3)
            if package.isOutdated {
                BrewUpdateBadge()
            }
            SizeColumn(byteCount: package.sizeBytes)
            if package.isOutdated {
                Button("Upgrade") { model.requestUpgrade(package) }
                    .buttonStyle(.sweepQuiet)
                    .disabled(model.isRunningAction)
            }
        }
        .frame(height: SweepTokens.inventoryRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(package.name), \(SweepFormat.bytes(package.sizeBytes))\(package.isOutdated ? ", update available" : "")")
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            Text("Maintenance")
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
            SectionCard {
                VStack(alignment: .leading, spacing: SweepTokens.s3) {
                    if let cache = model.snapshot.cache {
                        HStack(spacing: SweepTokens.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download Cache")
                                    .font(SweepFont.rowTitle)
                                    .foregroundStyle(.primary)
                                Text(cache.path)
                                    .font(SweepFont.monoSmall)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: SweepTokens.s3)
                            SizeColumn(byteCount: cache.sizeBytes, emphasized: true)
                        }
                    }
                    HStack(spacing: SweepTokens.s3) {
                        Button("Clean Cache") { model.requestCleanup() }
                            .buttonStyle(.sweepQuiet)
                            .disabled(model.isRunningAction)
                        Button("Remove Unused Dependencies") { model.requestAutoremove() }
                            .buttonStyle(.sweepQuiet)
                            .disabled(model.isRunningAction)
                        if model.isRunningAction {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Footnote("Both preview exactly what would change before anything runs.", symbol: "eye")
                }
                .padding(SweepTokens.s4)
            }
        }
    }

    private var consoleSection: some View {
        DisclosureGroup {
            ScrollView {
                Text(model.consoleLog)
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SweepTokens.s3)
            }
            .frame(height: 140)
            .background(SweepTokens.ground)
            .clipShape(RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous))
            .padding(.top, SweepTokens.s2)
        } label: {
            Text("Command Output")
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
        }
    }
}

/// "Update available", in the kinetic accent — deliberately not `TierBadge`: that vocabulary is
/// deletion-safety tiers, and an outdated formula is not a safety classification (PLAN §5: tier
/// amber/red stay exclusive to that system).
private struct BrewUpdateBadge: View {
    var body: some View {
        Text("UPDATE")
            .font(SweepFont.badge)
            .tracking(0.5)
            .foregroundStyle(SweepTokens.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SweepTokens.accent.opacity(0.12))
            )
    }
}

/// Preview-first confirmation, shared by cleanup/autoremove/upgrade. `isReady` is false while a
/// preview fetch is still in flight (`previewText` reads "Checking…") — the Confirm button stays
/// disabled for exactly that span, so nothing can run before its own preview has actually landed.
private struct BrewCommandPreviewSheet: View {
    let action: HomebrewPendingAction
    let isReady: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SweepTokens.s2) {
                Text(action.title)
                    .font(SweepFont.screenTitle)
                    .foregroundStyle(.primary)
                Text("Preview \u{2014} nothing runs until you confirm.")
                    .font(SweepFont.screenSubtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.top, SweepTokens.s5)
            .padding(.bottom, SweepTokens.s4)

            Divider()

            ScrollView {
                Text(action.previewText)
                    .font(SweepFont.mono)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SweepTokens.s4)
            }
            .frame(maxHeight: 260)
            .background(SweepTokens.ground)

            Divider()
            HStack(spacing: SweepTokens.s3) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut(.cancelAction)
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .disabled(!isReady)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SweepTokens.s5)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
