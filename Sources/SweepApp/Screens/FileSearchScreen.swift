import SweepUI
import SwiftUI

/// File Search (Toolbox, PLAN backlog promotion): fast name search across the user's home, sorted
/// by size — the PearCleaner-style "find that huge file by name" hub. Logic and mutation state
/// live in `FileSearchModel`/`FileSearchService` (`Sources/SweepApp/Toolbox/FileSearchService.
/// swift`); this file is the view only.
struct FileSearchScreen: View {
    @State private var model = FileSearchModel()
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScreenHeader(
                title: "File Search",
                subtitle: "Find any file by name, sorted by what it costs you."
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if model.phase == .searching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    // The screen's hero control (task spec) — deliberately wider than every other
                    // search field in the app.
                    SweepSearchField(text: $query, prompt: "File or folder name")
                        .frame(width: 300)
                    Picker("Sort", selection: $model.sortOrder) {
                        ForEach(FileSearchSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: model.phase)
        .onChange(of: query) { _, newValue in model.queryChanged(newValue) }
        .onDisappear { model.cancel() }
        .confirmationDialog(
            model.pendingTrash.map { "Move \u{201C}\($0.name)\u{201D} to the Trash?" } ?? "",
            isPresented: Binding(
                get: { model.pendingTrash != nil },
                set: { if !$0 { model.cancelTrash() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.cancelTrash() }
        } message: {
            if let entry = model.pendingTrash {
                Text(entry.bytes.map { bytes in
                    "Frees \(SweepFormat.bytes(bytes)). Goes to the Trash \u{2014} restore from there to undo."
                } ?? "Goes to the Trash \u{2014} restore from there to undo.")
            }
        }
        .alert(
            "Couldn\u{2019}t Move to Trash",
            isPresented: Binding(
                get: { model.trashError != nil },
                set: { if !$0 { model.dismissTrashError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissTrashError() }
        } message: {
            Text(model.trashError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .idle {
            idleState
        } else if model.entries.isEmpty {
            if model.phase == .searching {
                InventoryEmptyState(symbol: "magnifyingglass", title: "Searching\u{2026}")
            } else {
                InventoryEmptyState(
                    symbol: "questionmark.folder",
                    title: "No matches",
                    message: "Spotlight found nothing named \u{201C}\(model.lastQuery)\u{201D} in your home folder."
                )
            }
        } else {
            resultsList
        }
    }

    private var idleState: some View {
        Group {
            if query.isEmpty {
                InventoryEmptyState(
                    symbol: "magnifyingglass",
                    title: "Search your home folder",
                    message: "Type a file or folder name \u{2014} backed by Spotlight, so matches "
                        + "appear instantly across your whole home folder."
                )
            } else {
                InventoryEmptyState(
                    symbol: "textformat.abc",
                    title: "Keep typing",
                    message: "Type at least \(FileSearchLogic.minimumQueryLength) characters to search."
                )
            }
        }
    }

    private var resultsList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.visible.shown) { entry in
                    FileSearchRow(
                        entry: entry,
                        onReveal: { model.reveal(entry) },
                        onTrash: { model.requestTrash(entry) }
                    )
                }
                if model.visible.overflow > 0 {
                    Text("and \(SweepFormat.count(model.visible.overflow)) more \u{2014} refine the search")
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, SweepTokens.s4)
                        .padding(.vertical, SweepTokens.s3)
                }
                Color.clear.frame(height: SweepTokens.s4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SweepTokens.ground)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            Divider()
            if model.phase == .results, !model.entries.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Text(model.resultsCaption)
                        .font(SweepFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SweepTokens.s5)
                .padding(.top, SweepTokens.s3)
            }
            Footnote(
                "Backed by Spotlight. Folders show their own entry size; trash anything with one "
                    + "click \u{2014} it goes to the Trash, never deleted outright.",
                symbol: "bolt.fill"
            )
            .padding(.horizontal, SweepTokens.s5)
            .padding(.top, model.phase == .results && !model.entries.isEmpty ? 0 : SweepTokens.s3)

            if let note = model.skippedSummary {
                Footnote(note, symbol: "icloud.slash")
                    .padding(.horizontal, SweepTokens.s5)
            }
            Color.clear.frame(height: SweepTokens.s2)
        }
        .background(.bar)
    }
}

/// One flat-list row: kind glyph, name, home-abbreviated parent path, size (or a "—" placeholder
/// while still sizing), and hover-only Reveal/Trash actions.
private struct FileSearchRow: View {
    let entry: FileSearchEntry
    let onReveal: () -> Void
    let onTrash: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: FileSearchLogic.symbol(for: entry.kind))
                .font(.system(size: 13.5, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 19, alignment: .center)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.parentPath)
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: SweepTokens.s3)

            HStack(spacing: SweepTokens.s2) {
                Button(action: onReveal) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(entry.name) in Finder")

                Button(action: onTrash) {
                    Image(systemName: "trash")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Move to Trash")
                .accessibilityLabel("Move \(entry.name) to the Trash")
            }
            .frame(width: 52, alignment: .trailing)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)

            SizeColumn(value: sizeParts.value, unit: sizeParts.unit, font: SweepFont.mono, emphasized: false)
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .frame(height: SweepTokens.inventoryRowHeight)
        .background {
            RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                .fill(isHovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
        }
        .padding(.horizontal, SweepTokens.s1 + 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.row, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.parentPath), \(sizeAccessibilityLabel)")
    }

    private var sizeParts: (value: String, unit: String) {
        guard let bytes = entry.bytes else { return ("\u{2014}", "") }
        return SweepFormat.split(bytes)
    }

    private var sizeAccessibilityLabel: String {
        entry.bytes.map { SweepFormat.bytes($0) } ?? "size not yet known"
    }
}
