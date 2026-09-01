import SwiftUI

/// Sweep design tokens. Single kinetic accent; semantic colors reserved for safety tiers.
/// System materials + system light/dark everywhere; no hardcoded surface colors in views.
public enum SweepTokens {
    // Accent: reserved for progress, results, the scan sweep. Nothing else.
    public static let accent = Color(.displayP3, red: 0.16, green: 0.78, blue: 0.66)

    // Safety-tier semantics (never used for decoration)
    public static let tierSafe = accent
    public static let tierCaution = Color.orange
    public static let tierExpert = Color.red

    // Spacing scale
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 40

    public static let cornerRadius: CGFloat = 10

    /// Oversized animated number (GB found / freed): the app's visual signature.
    public static func heroNumberFont(size: CGFloat = 56) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    /// Byte counts, paths, anything columnar.
    public static let dataFont: Font = .system(.body, design: .monospaced)
}
