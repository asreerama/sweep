import AppKit
import SwiftUI

/// The icon of a *thing a person installed* — an app's real icon where one could be resolved, and
/// a quiet glyph tile where one could not.
///
/// Distinct from ``ModuleIcon`` on purpose. `ModuleIcon` is wayfinding for Sweep's own modules and
/// owns the muted hue palette; this renders someone else's identity, where the color comes from
/// their icon and inventing one for the fallback would be Sweep asserting a brand that does not
/// exist. So the fallback is deliberately neutral: hairline fill, hairline rim, secondary glyph.
public struct IdentityTile: View {
    private let image: NSImage?
    private let symbol: String
    private let diameter: CGFloat

    public init(image: NSImage? = nil, symbol: String, diameter: CGFloat = 32) {
        self.image = image
        self.symbol = symbol
        self.diameter = diameter
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: diameter * 0.26, style: .continuous)
                    .fill(SweepTokens.hairline)
                    .overlay {
                        RoundedRectangle(cornerRadius: diameter * 0.26, style: .continuous)
                            .strokeBorder(SweepTokens.hairline, lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: diameter * 0.46, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

#Preview("Identity tiles") {
    HStack(spacing: SweepTokens.s3) {
        IdentityTile(image: NSWorkspace.shared.icon(forFile: "/System/Applications/Safari.app"), symbol: "app.badge")
        IdentityTile(symbol: "shippingbox")
        IdentityTile(symbol: "terminal")
        IdentityTile(symbol: "apple.logo")
    }
    .padding(SweepTokens.s5)
}
