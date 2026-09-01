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
            Text(tier.label.uppercased())
                .font(SweepFont.badge)
                .tracking(0.5)
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
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
