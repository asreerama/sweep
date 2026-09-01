import SwiftUI

/// Motion moment two (PLAN §5): the ring collapsing inward while the byte counter rolls down.
///
/// `remainingFraction` runs from 1.0 (nothing cleaned yet) to 0.0 (finished). Two things move
/// together off that one value — the stroke trims back toward nothing and the ring itself scales
/// down slightly — so completion reads as the ring consuming itself rather than as a countdown
/// drawn on a ring that never otherwise changes. Both are plain `.animation(_:value:)` bindings,
/// so a fast run whose updates land faster than one spring settles just retargets the spring onto
/// the newest value instead of queueing a second animation behind the first.
public struct CleanRing<Content: View>: View {
    private let remainingFraction: Double
    private let diameter: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1

    public init(remainingFraction: Double, diameter: CGFloat = 240, @ViewBuilder content: () -> Content) {
        self.remainingFraction = min(max(remainingFraction, 0), 1)
        self.diameter = diameter
        self.content = content()
    }

    private var trackWidth: CGFloat { max(1, diameter * 0.006) }
    private var sweepWidth: CGFloat { max(2, diameter * 0.0125) }
    /// Same floor `ScanRing`'s completed state scales to, so a Clean flow launched straight off a
    /// Smart Scan result reads as one continuous ring rather than two rings of different sizes.
    private var scale: CGFloat { (reduceMotion ? 1 : 0.86 + 0.14 * remainingFraction) * pulseScale }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.quaternary, lineWidth: trackWidth)

            Circle()
                .inset(by: sweepWidth / 2)
                .trim(from: 0, to: remainingFraction)
                .stroke(SweepTokens.ringSweep, style: StrokeStyle(lineWidth: sweepWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .scaleEffect(scale)
                .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.ring, value: remainingFraction)

            content
                .frame(maxWidth: diameter * 0.74)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .onChange(of: remainingFraction) { _, newValue in
            // "One pulse at zero" (PLAN §5, "Motion continuity"): the same completion beat
            // `ScanRing` gives a finished scan, given here to a finished clean instead of a
            // second, different flourish — one motion vocabulary for "this ring just finished."
            guard newValue == 0, !reduceMotion else { return }
            withAnimation(SweepMotion.completionPulse) { pulseScale = 1.05 }
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(SweepMotion.completionPulse) { pulseScale = 1.0 }
            }
        }
    }
}

extension CleanRing where Content == EmptyView {
    public init(remainingFraction: Double, diameter: CGFloat = 240) {
        self.init(remainingFraction: remainingFraction, diameter: diameter) { EmptyView() }
    }
}

/// The Clean flow's progress state: hero counter rolling down, ring collapsing inward, current
/// item caption underneath. No Cancel — a trash-only operation is cheap to undo from the Trash
/// itself, and a cancel button here would just invite reading the header of a report we no
/// longer have a use for.
public struct CleanProgressState: View {
    private let update: CleanProgressUpdate
    private let totalBytes: Int64
    private let diameter: CGFloat

    public init(update: CleanProgressUpdate, totalBytes: Int64, diameter: CGFloat = 224) {
        self.update = update
        self.totalBytes = totalBytes
        self.diameter = diameter
    }

    private var remainingFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(update.remainingBytes) / Double(totalBytes)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: SweepTokens.s5)
            CleanRing(remainingFraction: remainingFraction, diameter: diameter) {
                HeroByteCounter(
                    byteCount: update.remainingBytes,
                    size: 52,
                    label: "Cleaning",
                    caption: "\(SweepFormat.itemCount(update.remainingItems)) left"
                )
            }
            Spacer().frame(height: SweepTokens.s5)
            PathTicker(path: update.currentItemCaption)
            Spacer(minLength: SweepTokens.s5)
        }
        .padding(.horizontal, SweepTokens.s5)
    }
}

#Preview("Clean progress") {
    CleanProgressPreview()
        .frame(width: 560, height: 480)
}

private struct CleanProgressPreview: View {
    @State private var update = CleanProgressUpdate(
        remainingBytes: 9_810_000_000,
        remainingItems: 18_204,
        currentItemCaption: "~/Library/Caches/Google/Chrome/Default/Cache_Data/f_0002a1"
    )

    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            CleanProgressState(update: update, totalBytes: 9_810_000_000)
            Button("Advance") {
                let nextBytes = max(0, update.remainingBytes - 2_400_000_000)
                let nextItems = max(0, update.remainingItems - 4_400)
                update = CleanProgressUpdate(
                    remainingBytes: nextBytes,
                    remainingItems: nextItems,
                    currentItemCaption: nextBytes == 0 ? nil : "~/Library/Caches/com.example.app/Cache_Data"
                )
            }
        }
    }
}
