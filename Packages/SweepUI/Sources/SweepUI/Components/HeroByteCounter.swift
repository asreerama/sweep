import SwiftUI

/// The signature number: oversized SF Pro Display, tight tracking, digits that roll.
///
/// The roll is `contentTransition(.numericText(value:))` driven by a spring, so the glyph
/// interpolation happens on the render thread and stays smooth at 120 Hz while the scan pushes
/// new totals in. Digits are monospaced and the value carries three significant figures at
/// every magnitude, so the layout never reflows while the number climbs.
///
/// Under Reduce Motion the transition is dropped entirely and the text simply updates.
public struct HeroByteCounter: View {
    private let byteCount: Int64
    private let size: CGFloat
    private let label: String?
    private let caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        byteCount: Int64,
        size: CGFloat = 54,
        label: String? = nil,
        caption: String? = nil
    ) {
        self.byteCount = byteCount
        self.size = size
        self.label = label
        self.caption = caption
    }

    public var body: some View {
        let parts = SweepFormat.split(byteCount)

        VStack(spacing: size * 0.06) {
            if let label {
                Text(label.uppercased())
                    .font(SweepFont.badge)
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: size * 0.07) {
                Text(parts.value)
                    .font(SweepFont.hero(size))
                    .tracking(SweepFont.heroTracking(size))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(byteCount)))
                Text(parts.unit)
                    .font(SweepFont.heroUnit(size * 0.26))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .contentTransition(.identity)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .animation(reduceMotion ? nil : SweepMotion.counter, value: byteCount)

            if let caption {
                // No transition on the caption. It changes several times a second while a scan
                // runs, and a second animated number under the first is noise competing with
                // the one number the screen is about.
                Text(caption)
                    .font(SweepFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Total")
        .accessibilityValue("\(parts.value) \(parts.unit)\(caption.map { ", \($0)" } ?? "")")
    }
}

#Preview("Hero counter") {
    StatefulPreview(false) { _ in
        HeroCounterDemo()
    }
    .padding(SweepTokens.s6)
}

private struct HeroCounterDemo: View {
    @State private var bytes: Int64 = 9_812_345_678

    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            HeroByteCounter(byteCount: bytes, size: 72, label: "Found", caption: "48,201 items")
            HeroByteCounter(byteCount: bytes / 97, size: 40)
            Button("Roll") { bytes = Int64.random(in: 1_000_000...900_000_000_000) }
        }
    }
}
