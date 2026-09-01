import SwiftUI

/// The Clean flow's confirmation sheet: what is about to move to the Trash, and nothing else.
///
/// Every number here is the same one the hero counter is about to roll down from — no rounding,
/// no "about", because this is the last screen the user sees before anything moves.
public struct CleanConfirmSheet: View {
    private let summary: CleanRequestSummary
    private let onCancel: () -> Void
    private let onClean: () -> Void

    public init(summary: CleanRequestSummary, onCancel: @escaping () -> Void, onClean: @escaping () -> Void) {
        self.summary = summary
        self.onCancel = onCancel
        self.onClean = onClean
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SweepTokens.s2) {
                Text("Clean \(SweepFormat.itemCount(summary.itemCount))?")
                    .font(SweepFont.screenTitle)
                    .foregroundStyle(.primary)
                HStack(spacing: SweepTokens.s2 - 2) {
                    Text(SweepFormat.bytes(summary.totalBytes))
                        .font(SweepFont.monoEmphasis)
                        .foregroundStyle(.primary)
                    Text("will move to the Trash.")
                        .font(SweepFont.screenSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.top, SweepTokens.s5)
            .padding(.bottom, SweepTokens.s4)

            Divider()

            VStack(alignment: .leading, spacing: SweepTokens.s3) {
                Text("VOLUMES")
                    .font(SweepFont.sidebarSection)
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                SectionCard {
                    ForEach(Array(summary.volumes.enumerated()), id: \.element.id) { index, volume in
                        if index > 0 { Divider() }
                        volumeRow(volume)
                    }
                }

                Footnote("Everything goes to Trash and can be restored.", symbol: "arrow.uturn.backward")
            }
            .padding(SweepTokens.s5)

            Divider()
            HStack(spacing: SweepTokens.s3) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut(.cancelAction)
                Button("Clean", action: onClean)
                    .buttonStyle(.sweepDestructive())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SweepTokens.s5)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func volumeRow(_ volume: CleanVolume) -> some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .center)
            Text(volume.name)
                .font(SweepFont.rowTitle)
                .foregroundStyle(.primary)
            Text(SweepFormat.itemCount(volume.itemCount))
                .font(SweepFont.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: SweepTokens.s3)
            SizeColumn(byteCount: volume.byteCount, font: SweepFont.mono, emphasized: true)
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .frame(height: SweepTokens.inventoryRowHeight)
    }
}

#Preview("Clean confirm sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CleanConfirmSheet(
                summary: CleanRequestSummary(
                    itemCount: 18_204,
                    totalBytes: 9_810_000_000,
                    volumes: [
                        CleanVolume(id: "1", name: "Macintosh HD", itemCount: 18_190, byteCount: 9_760_000_000),
                        CleanVolume(id: "2", name: "DevSSD", itemCount: 14, byteCount: 50_000_000),
                    ]
                ),
                onCancel: {},
                onClean: {}
            )
        }
        .frame(width: 500, height: 500)
}
