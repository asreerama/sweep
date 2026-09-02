import SwiftUI

/// Menubar stat row: glyph, label, tabular readout, and a hairline bar.
///
/// Motion moment three lives here. The bar breathes only while memory pressure is off normal,
/// so the movement carries information rather than decoration — a still gauge means nothing is
/// wrong. Reduce Motion holds it steady and the colour alone carries the level.
public struct SweepStatRow: View {
    private let symbol: String
    private let title: String
    private let valueText: String
    private let fraction: Double?
    private let tint: Color
    private let isBreathing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathPhase = false

    public init(
        symbol: String,
        title: String,
        valueText: String,
        fraction: Double? = nil,
        tint: Color = SweepTokens.accent,
        isBreathing: Bool = false
    ) {
        self.symbol = symbol
        self.title = title
        self.valueText = valueText
        self.fraction = fraction
        self.tint = tint
        self.isBreathing = isBreathing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SweepTokens.s2 - 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: SweepTokens.s2)
                Text(valueText)
                    .font(SweepFont.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.fill.tertiary)
                        Capsule(style: .continuous)
                            .fill(tint)
                            .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
                            .opacity(shouldBreathe && breathPhase ? 0.5 : 1)
                    }
                }
                .frame(height: 3)
                .animation(SweepMotion.counter, value: fraction)
            }
        }
        .onAppear { syncBreath() }
        .onChange(of: shouldBreathe) { _, _ in syncBreath() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(valueText)")
    }

    private var shouldBreathe: Bool { isBreathing && !reduceMotion }

    private func syncBreath() {
        if shouldBreathe {
            withAnimation(SweepMotion.breathe) { breathPhase = true }
        } else {
            withAnimation(SweepMotion.crossfade) { breathPhase = false }
        }
    }
}

#Preview("Stat rows") {
    VStack(alignment: .leading, spacing: SweepTokens.s3) {
        SweepStatRow(symbol: "memorychip", title: "Memory", valueText: "22.1 / 32 GB", fraction: 0.69)
        SweepStatRow(symbol: "gauge.with.dots.needle.67percent", title: "Pressure", valueText: "Warning",
                     fraction: 0.72, tint: SweepTokens.tierCaution, isBreathing: true)
        SweepStatRow(symbol: "cpu", title: "CPU", valueText: "14%")
        SweepStatRow(symbol: "internaldrive", title: "Macintosh HD", valueText: "402 / 994 GB", fraction: 0.4)
    }
    .padding(SweepTokens.s3)
    .frame(width: 268)
    .background(.ultraThinMaterial)
}
