import SwiftUI

/// Per-module wayfinding color (PLAN §5, volume-raise: "System Settings-style colored sidebar
/// icons... not a dev tool"). Keyed by the SF Symbol name each module already carries — every
/// call site already has a symbol, so this needs no new per-destination enum of its own and stays
/// usable from both the sidebar (`Destination.symbol`) and a scan result's group header
/// (`InventoryGroup.symbol`) without either one depending on the other.
///
/// Deliberately excludes orange and red: those are `SweepTokens.tierCaution`/`tierExpert`/
/// `danger`, and a colorful module icon that happened to land on either would read as a safety
/// warning it is not. Also kept away from indigo/violet — `SweepTokens.accent` — so a module
/// badge never reads as "this is the highlighted action." Unrecognized symbols (item-level
/// glyphs like `shippingbox` or `iphone`, which stay monochrome on purpose — hierarchy at the row
/// level is still weight and space, not color) fall back to `nil`, and callers show their
/// existing neutral style.
///
/// Palette v2 (PLAN §5): every hue below sits at roughly the same muted, pastel-leaning
/// lightness — no single module badge should read as more "important" than another purely
/// because its color happens to be punchier.
public enum SweepModuleHue {
    /// Keyed by both the current glyph set (v2, the modern-register symbols) and the v1
    /// literal-object names: group headers and other identity call sites may still carry a v1
    /// symbol, and a module's hue must never depend on which vintage of its glyph a call site
    /// happens to hold.
    public static func color(forSymbol symbol: String) -> Color? {
        switch symbol {
        case "sparkles": SweepTokens.accent                                        // Smart Scan
        case "bubbles.and.sparkles", "trash": Color(hex: 0x5B93D9)                 // System Junk — muted blue
        case "archivebox", "doc.zipper": Color(hex: 0x4FB6A6)                      // Large & Old Files — muted teal
        case "memorychip": Color(hex: 0x5CB37B)                                    // Memory — muted green
        case "slider.horizontal.3", "wrench.and.screwdriver": Color(hex: 0x6C93A6) // Maintenance — muted slate
        case "bolt", "power": Color(hex: 0xA67CB5)                                 // Startup Items — muted plum
        case "app.dashed", "xmark.bin": Color(hex: 0xD97BA0)                       // Uninstaller — muted rose
        case "chevron.left.forwardslash.chevron.right", "hammer": Color(hex: 0x8B8FD6) // Developer — muted lavender
        case "mug": Color(hex: 0xB08968)                                           // Homebrew — muted tan
        case "scissors": Color(hex: 0x4F9DB6)                                      // App Lipo — muted petrol
        case "puzzlepiece.extension": Color(hex: 0x9AA25C)                         // Plugins — muted olive
        case "cube": Color(hex: 0x8FA0B8)                                          // Packages — muted steel
        case "text.magnifyingglass": Color(hex: 0x6BAF8D)                          // File Search — muted jade
        default: nil
        }
    }
}

extension Color {
    /// `Color(hex: 0x5B93D9)` — the module-hue palette's literals, kept legible instead of eight
    /// repeated `Color(.sRGB, red:green:blue:)` calls.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A module's icon, badged in its hue — the sidebar's "System Settings" icon, reused anywhere
/// else a module needs the same identity (a group header, an inventory-template hub tile).
///
/// Falls back to a plain hierarchical glyph with no badge when `symbol` has no assigned hue
/// (`SweepModuleHue.color(forSymbol:)` returns `nil`) — item-level rows never get a badge, only
/// modules do.
public struct ModuleIcon: View {
    private let symbol: String
    private let diameter: CGFloat

    public init(symbol: String, diameter: CGFloat = 22) {
        self.symbol = symbol
        self.diameter = diameter
    }

    public var body: some View {
        if let hue = SweepModuleHue.color(forSymbol: symbol) {
            // The "pressable app icon" treatment, not a flat color square: the hue's own
            // gradient for the base, a top light-to-grounded-base wash and a hairline inner
            // rim for glassy depth, and a shadow tinted in the chip's own hue so it lifts off
            // the sidebar material. Everything scales off `diameter`, so the same identity
            // holds from a 26 pt toolbox chip to a hub tile.
            RoundedRectangle(cornerRadius: diameter * 0.28, style: .continuous)
                .fill(hue.gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: diameter * 0.28, style: .continuous)
                        .fill(LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.28), location: 0),
                                .init(color: .white.opacity(0.02), location: 0.5),
                                .init(color: .black.opacity(0.10), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: diameter * 0.28, style: .continuous)
                        .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                }
                .frame(width: diameter, height: diameter)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.52, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                }
                .shadow(color: hue.opacity(0.32), radius: diameter * 0.10, y: diameter * 0.05)
        } else {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: diameter, height: diameter)
        }
    }
}

#Preview("Module hues") {
    let symbols = ["sparkles", "trash", "doc.zipper", "memorychip", "wrench.and.screwdriver",
                   "power", "xmark.bin", "hammer", "mug", "shippingbox"]
    return VStack(alignment: .leading, spacing: SweepTokens.s3) {
        ForEach(symbols, id: \.self) { symbol in
            HStack(spacing: SweepTokens.s3) {
                ModuleIcon(symbol: symbol)
                Text(symbol).font(SweepFont.mono)
            }
        }
    }
    .padding(SweepTokens.s5)
}
