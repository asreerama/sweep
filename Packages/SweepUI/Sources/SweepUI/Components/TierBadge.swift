import SwiftUI

/// Safety-tier badge. The only place amber and red appear in the app.
///
/// `safe` renders nothing by default. A row list is mostly safe items, and stamping ten
/// thousand green "SAFE" pills down a column turns the one signal that matters — the amber and
/// red ones — into wallpaper. Group headers pass `showsSafe: true`, where the badge is
/// reassurance and there are only a handful of them.
public struct TierBadge: View {
    private let tier: SweepTier
    private let showsSafe: Bool

    public init(_ tier: SweepTier, showsSafe: Bool = false) {
        self.tier = tier
        self.showsSafe = showsSafe
    }

    public var body: some View {
        if tier != .safe || showsSafe {
            // Soft tinted pill (Palette v2): a 12% hue wash, never a solid fill, and no border —
            // the wash alone is enough separation against the card/ground tokens it sits on.
            Text(tier.label.uppercased())
                .font(SweepFont.badge)
                .tracking(0.5)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
                .accessibilityLabel("\(tier.label) tier")
        }
    }

    private var tint: Color {
        switch tier {
        case .safe: SweepTokens.tierSafe
        case .caution: SweepTokens.tierCaution
        case .expert: SweepTokens.tierExpert
        }
    }
}

#Preview("Tier badges") {
    VStack(alignment: .leading, spacing: SweepTokens.s3) {
        HStack(spacing: SweepTokens.s2) {
            TierBadge(.safe, showsSafe: true)
            TierBadge(.caution)
            TierBadge(.expert)
        }
        Text("safe hidden in row context:")
            .font(SweepFont.caption)
            .foregroundStyle(.secondary)
        TierBadge(.safe)
    }
    .padding(SweepTokens.s5)
}
