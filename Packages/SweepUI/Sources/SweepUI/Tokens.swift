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

    // Spacing scale. Every gap in the app is one of these.
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 40
    public static let s7: CGFloat = 64

    public static let cornerRadius: CGFloat = 10
    /// Sidebar rows, inventory rows, badges.
    public static let rowRadius: CGFloat = 6

    /// Fixed column widths for the size readout, so every row's digits line up across groups
    /// without a Table. Value right-aligned, unit left-aligned beside it.
    public static let sizeValueWidth: CGFloat = 44
    public static let sizeUnitWidth: CGFloat = 24
    public static let sizeColumnWidth: CGFloat = 72

    /// Indent applied to inventory rows so their checkbox sits under the group header's,
    /// past the header's disclosure chevron.
    public static let rowDisclosureIndent: CGFloat = 20

    public static let inventoryRowHeight: CGFloat = 34
    public static let summaryRowHeight: CGFloat = 44

    /// Oversized animated number (GB found / freed): the app's visual signature.
    public static func heroNumberFont(size: CGFloat = 56) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }

    /// Byte counts, paths, anything columnar.
    public static let dataFont: Font = .system(.body, design: .monospaced)
}

/// The type ramp. Hierarchy is carried by weight and size, never by color alone.
/// SF Pro (system) for text, SF Mono for anything columnar or path-shaped.
public enum SweepFont {
    // Sidebar, two tiers.
    public static let sidebarPrimary = Font.system(size: 13, weight: .medium)
    public static let sidebarToolbox = Font.system(size: 12, weight: .regular)
    public static let sidebarSection = Font.system(size: 10, weight: .semibold)

    // Content pane.
    public static let screenTitle = Font.system(size: 22, weight: .semibold)
    public static let screenSubtitle = Font.system(size: 11.5, weight: .regular)
    public static let sectionTitle = Font.system(size: 12.5, weight: .semibold)

    // Rows.
    public static let rowTitle = Font.system(size: 12.5, weight: .regular)
    public static let rowTitleEmphasis = Font.system(size: 13, weight: .medium)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let badge = Font.system(size: 9, weight: .semibold)

    // Data. Always paired with `.monospacedDigit()` at the call site where the glyphs must align.
    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    public static let monoEmphasis = Font.system(size: 12.5, weight: .medium, design: .monospaced)

    /// SF Pro Display is selected automatically at these sizes; tracking is tightened by hand.
    public static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    public static func heroUnit(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }

    /// Optical tracking for the hero number, proportional to its size.
    public static func heroTracking(_ size: CGFloat) -> CGFloat { -size * 0.028 }
}

/// Motion vocabulary. Three orchestrated moments (PLAN §5), springs only, nothing driven by a
/// `Timer`: every animation below is handed to Core Animation and interpolated on the render
/// thread, which is what keeps it honest at 120 Hz.
public enum SweepMotion {
    /// The hero counter settling on a new value. Critically damped and short on purpose: the
    /// digit roll has to *finish* before the next scan total arrives, or every frame starts a
    /// new transition over the last one and the number reads as a permanent smear.
    /// Pair it with a display cadence no faster than this duration.
    public static let counter = Animation.spring(response: 0.3, dampingFraction: 1.0)
    /// Slowest the hero number should be re-set, in seconds. Anything faster overlaps ``counter``.
    public static let counterCadence: Double = 0.28
    /// The ring collapsing inward when a scan finishes.
    public static let ring = Animation.spring(response: 0.55, dampingFraction: 0.84)
    /// Drawing the settled ring. Critically damped on purpose: a spring that overshoots a
    /// `trim` past 1.0 gets clamped and visibly stalls at the top of the circle.
    public static let ringTrim = Animation.spring(response: 0.62, dampingFraction: 1.0)
    /// Screen-level layout changes (idle → scanning → results).
    public static let layout = Animation.spring(response: 0.52, dampingFraction: 0.9)
    /// Row-level state (selection, disclosure).
    public static let row = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// The Reduce Motion substitute for anything kinetic.
    public static let crossfade = Animation.easeInOut(duration: 0.22)

    /// Seconds for one full turn of the scan sweep.
    public static let sweepPeriod: Double = 1.4
    /// Menubar gauge breathing under memory pressure.
    public static let breathe = Animation.easeInOut(duration: 1.7).repeatForever(autoreverses: true)
}
