import SwiftUI
import SweepUI

/// Homebrew (module 9, PLAN §3): a typed GUI over `brew` — installed formulae/casks with sizes,
/// outdated packages, cache size, and preview-first maintenance actions.
///
/// Read-mostly by design: every mutation (`cleanup`, `autoremove`, per-item `upgrade`) goes
/// through `HomebrewModel`'s preview-then-confirm flow, never runs on first tap, and streams its
/// raw output into the console disclosure at the bottom rather than a silent success/fail toast.
struct HomebrewScreen: View {
    // Shared, launch-warmed model from `AppState` — not a per-screen `@State` instance, so
    // navigating away and back does not re-run `brew`.
    @Environment(HomebrewModel.self) private var model
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
                            .frame(width: 240)
                    }
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") { Task { await model.refresh() } }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.loadState == .loading || model.isRefreshing)
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The model is warmed at launch (`AppState`), so this only loads if that has not happened
        // yet — revisiting the screen never re-runs `brew`. Manual reload is the Refresh button.
        .task { if model.loadState == .idle { await model.refresh() } }
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
                if !filteredOutdated.isEmpty {
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
                Divider().frame(height: 36)
                statTile(title: "Casks", value: SweepFormat.count(model.snapshot.casks.count))
                Divider().frame(height: 36)
                // "…" while `brew outdated` is still deciding — the staged load renders this
                // card seconds before the update check lands, and a hard "0" would read as
                // "everything is current" when the truth is "still checking."
                statTile(
                    title: "Outdated",
                    value: model.isCheckingUpdates && model.snapshot.outdated.isEmpty
                        ? "\u{2026}" : SweepFormat.count(model.snapshot.outdated.count),
                    tint: model.snapshot.outdated.isEmpty ? nil : SweepTokens.accent
                )
                Divider().frame(height: 36)
                statTile(
                    title: "Cache",
                    value: model.snapshot.cache.map { SweepFormat.bytes($0.sizeBytes) }
                        ?? (model.isCheckingUpdates ? "\u{2026}" : "\u{2013}")
                )
            }
            .padding(SweepTokens.s4)
        }
    }

    private func statTile(title: String, value: String, tint: Color? = nil) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
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
            HStack(spacing: SweepTokens.s2) {
                Text("Outdated")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer()
                if let progress = model.upgradeAllProgress {
                    Text("Upgrading \(progress.current ?? "\u{2026}") \u{00B7} \(progress.completed) of \(progress.total)")
                        .font(SweepFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Button("Update All (\(model.snapshot.outdated.count))") { model.requestUpgradeAll() }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.isRunningAction || !model.upgradingPackageIDs.isEmpty)
                }
            }
            if let progress = model.upgradeAllProgress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(SweepTokens.accent)
                    .animation(SweepMotion.layout, value: progress.completed)
            }
            SectionCard {
                ForEach(Array(filteredOutdated.enumerated()), id: \.element.id) { index, package in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    packageRow(package)
                        .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
        }
    }

    /// One folded query applied to EVERY section (user-reported: filtering only the Installed
    /// list while the Outdated section — the first thing on screen — ignored the field read as
    /// "search doesn't work"). Pre-folded `searchKey`s + `contains`, never per-keystroke ICU.
    private var foldedQuery: String {
        SearchFold.fold(query.trimmingCharacters(in: .whitespaces))
    }

    private var filteredPackages: [BrewPackage] {
        let folded = foldedQuery
        let base = model.snapshot.packages
        let matched = folded.isEmpty ? base : base.filter { $0.searchKey.contains(folded) }
        return matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredOutdated: [BrewPackage] {
        let folded = foldedQuery
        guard !folded.isEmpty else { return model.snapshot.outdated }
        return model.snapshot.outdated.filter { $0.searchKey.contains(folded) }
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

    /// One package as a taller, self-explanatory card row: an icon chip that says what KIND of
    /// thing this is (a Mac app vs a command-line tool — "cask"/"formula" mean nothing to a
    /// non-technical user), a plain-language status line, and an emphasized size. The update state
    /// lives in the subtitle ("Update available · 1.2 → 1.4"), so no separate badge is needed.
    private func packageRow(_ package: BrewPackage) -> some View {
        HStack(spacing: SweepTokens.s3) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(package.isCask ? AnyShapeStyle(SweepTokens.accent.opacity(0.12)) : AnyShapeStyle(.fill.quaternary))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: package.isCask ? "macwindow" : "terminal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(package.isCask ? AnyShapeStyle(SweepTokens.accent) : AnyShapeStyle(.secondary))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(SweepFont.rowTitleEmphasis)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                packageSubtitle(package)
            }
            Spacer(minLength: SweepTokens.s3)
            // The staged load renders rows milliseconds after open, seconds before the disk walk
            // has sized them — a quiet placeholder for that span, never a lying "Zero KB".
            if model.isSizing, package.sizeBytes == 0 {
                Text("\u{2014}")
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .frame(width: SweepTokens.sizeColumnWidth, alignment: .trailing)
            } else {
                SizeColumn(byteCount: package.sizeBytes, emphasized: true)
            }
            upgradeAccessory(for: package)
            // Uninstall: routes through the same preview-then-confirm sheet as every other
            // mutation — the sheet is the confirmation dialog, naming the package, its size and
            // the exact command. Hidden while a batch run owns the rows.
            if model.upgradeAllProgress == nil, !model.upgradingPackageIDs.contains(package.id) {
                Button {
                    model.requestUninstall(package)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Uninstall \(package.name)")
                .disabled(model.isRunningAction)
                .accessibilityLabel("Uninstall \(package.name)")
            }
        }
        .padding(.vertical, SweepTokens.s2)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(package.name), \(package.isCask ? "Mac app" : "command-line tool"), \(SweepFormat.bytes(package.sizeBytes))\(package.isOutdated ? ", update available" : "")")
    }

    @ViewBuilder
    private func packageSubtitle(_ package: BrewPackage) -> some View {
        if let latest = package.latestVersion {
            HStack(spacing: SweepTokens.s1) {
                Text("Update available")
                    .font(SweepFont.caption)
                    .foregroundStyle(SweepTokens.accent)
                Text("\(package.installedVersion ?? "current") \u{2192} \(latest)")
                    .font(SweepFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            // "up to date" is only claimable once `brew outdated` has actually answered — while
            // the staged load's update check is in flight the row states just what it knows.
            Text([
                package.isCask ? "Mac app" : "Command-line tool",
                package.installedVersion,
                model.isCheckingUpdates ? nil : "up to date",
            ].compactMap(\.self).joined(separator: " \u{00B7} "))
                .font(SweepFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The trailing slot of a package row. Four states: a batch run replaces every Upgrade button
    /// with live text ("Upgrading…" on the active row, "Waiting…" on the rest); a per-item upgrade
    /// shows an in-row progress bar on exactly that row while every other row's Upgrade button
    /// stays enabled (one upgrade must never lock the others out); otherwise an outdated row gets
    /// its Upgrade button, disabled only during the exclusive actions (cleanup/autoremove/batch).
    @ViewBuilder
    private func upgradeAccessory(for package: BrewPackage) -> some View {
        if let progress = model.upgradeAllProgress {
            if progress.current == package.name {
                HStack(spacing: SweepTokens.s1 + 2) {
                    ProgressView().controlSize(.small)
                    Text("Upgrading\u{2026}")
                        .font(SweepFont.caption)
                        .foregroundStyle(SweepTokens.accent)
                }
            } else if package.isOutdated {
                Text("Waiting\u{2026}")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if model.upgradingPackageIDs.contains(package.id) {
            HStack(spacing: SweepTokens.s1 + 2) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 56)
                Text("Upgrading\u{2026}")
                    .font(SweepFont.caption)
                    .foregroundStyle(SweepTokens.accent)
            }
        } else if package.isOutdated {
            Button("Upgrade") { model.requestUpgrade(package) }
                .buttonStyle(.sweepQuiet)
                .disabled(model.isRunningAction)
        }
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
                            .disabled(model.isRunningAction || !model.upgradingPackageIDs.isEmpty)
                        Button("Remove Unused Dependencies") { model.requestAutoremove() }
                            .buttonStyle(.sweepQuiet)
                            .disabled(model.isRunningAction || !model.upgradingPackageIDs.isEmpty)
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
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
