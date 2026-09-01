import AppKit
import SwiftUI

/// Sweep design tokens. Palette v2 (PLAN §5): tinted neutrals and one soft indigo accent, defined
/// once here as the single source — everything else in SweepUI reads a token, never a literal
/// color or a bare system material.
///
/// Three color systems, kept deliberately separate: the kinetic ``accent`` (progress, results,
/// the scan sweep — one hue, one meaning), ``SweepModuleHue`` (muted, pastel-leaning wayfinding
/// color per module), and tier amber/red — exclusively semantic. Nothing above ever borrows
/// `tierCaution`/`tierExpert`/`danger` for decoration, and no module hue is allowed to be orange
/// or red, so a caution badge is never confused with "this sidebar item is Memory."
public enum SweepTokens {
    /// One color that renders differently per appearance, without needing `@Environment
    /// (\.colorScheme)` at every call site.
    ///
    /// This queries `NSApp.effectiveAppearance` directly rather than bridging through
    /// `NSColor(name:dynamicProvider:)`. The dynamic-provider form is the textbook approach and
    /// does work for a normally-composited window; it does not reliably re-resolve inside this
    /// app's offscreen screenshot harness (`SnapshotHarness`), which walks `CALayer.render(in:)`
    /// directly rather than going through AppKit's ordinary display cycle — every dynamic
    /// `NSColor` came back light there regardless of the forced appearance, while system
    /// materials and SwiftUI's own `.primary`/`.secondary` (environment-`colorScheme`-driven, a
    /// different mechanism entirely) rendered correctly dark. Reading the appearance eagerly each
    /// access is the trade for that: it is a computed property, not a dynamic color, so it is
    /// correct at the moment a view body runs but does not itself force a re-render when the
    /// system appearance flips while already on screen — in practice a view somewhere nearby
    /// almost always re-renders from that same system change anyway (materials and `.primary`
    /// text do observe it directly), but this is the one token mechanism in the app that is not
    /// independently live-reactive, and is documented here rather than silently assumed.
    static func adaptive(light: Color, dark: Color) -> Color {
        let isDark = (NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? dark : light
    }

    // MARK: - Accent (Palette v2: soft indigo, replacing the original teal)

    /// Reserved for progress, results, the scan sweep, and the one primary action per screen.
    /// Nothing else — see the type doc for the two other color systems this is kept separate from.
    public static var accent: Color {
        adaptive(light: Color(hex: 0x5E6AD2), dark: Color(hex: 0x7C8AEE))
    }

    // MARK: - Grounds and cards (Palette v2: tinted neutrals, not flat system materials)

    /// The page background: a faint indigo-biased tint rather than pure white/black, so a card
    /// sitting on it reads as a raised surface without needing a hard border to say so.
    public static var ground: Color {
        adaptive(light: Color(hex: 0xF7F8FA), dark: Color(hex: 0x16181D))
    }

    /// Elevated surfaces: `SectionCard`, rows, anything sitting a level above `ground`.
    public static var cardBackground: Color {
        adaptive(light: .white, dark: Color(hex: 0x1D2025))
    }

    /// Low-contrast dividers and hairline borders — a tint of the ground/card relationship, not
    /// a hard system separator line.
    public static var hairline: Color {
        adaptive(light: Color(hex: 0xE8EAF0), dark: Color(hex: 0x2A2E36))
    }

    /// The hero number's ink: one step off pure black/white (Palette v2), so the app's single
    /// largest piece of type reads as designed rather than as the platform default label color.
    public static var heroInk: Color {
        adaptive(light: Color(hex: 0x1A1B23), dark: Color(hex: 0xF0F1F5))
    }

    /// `SectionCard`'s elevation in light mode: a soft, diffuse shadow rather than a hard border
    /// doing all the separation work. Dark mode skips it — a shadow reads as a smudge on a dark
    /// ground, and the card/ground luminance step already carries the separation there.
    public static let cardShadow = Color.black.opacity(0.06)

    // Safety-tier semantics (never used for decoration)
    public static var tierSafe: Color { accent }
    public static let tierCaution = Color.orange
    public static let tierExpert = Color.red

    /// The one other place red appears: the Clean confirm sheet's destructive primary button.
    /// Distinct constant from `tierExpert` on purpose — one is a safety classification, the
    /// other is "this button moves things to the Trash," and they should stay free to diverge.
    public static let danger = Color.red

    /// The hero ring's settled stroke (PLAN §5 volume-raise): an angular gradient sweep around
    /// one hue family, not a flat line. `accent` is still the only color anything is measured
    /// against — this is depth on that same color, not a second one.
    public static var ringSweep: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [accent, accent.opacity(0.72), accent]),
            center: .center
        )
    }

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
    /// PLAN §5, "Motion continuity": how long the sweep takes to decelerate to rest once a scan
    /// lands, and how long the settled-ring trim waits before it starts closing — the two ends
    /// of the same choreography beat, kept as one constant so they can never drift apart.
    public static let decelerationDuration: Double = 0.5
    /// How long after the trim finishes closing a screen should morph its hero slot from the
    /// scanning layout into the results layout (PLAN §5): ring shrinks and moves, counter
    /// settles, result rows begin their stagger — all on this one beat.
    public static let resultsMorphDelay: Double = decelerationDuration + 0.55
    /// Menubar gauge breathing under memory pressure.
    public static let breathe = Animation.easeInOut(duration: 1.7).repeatForever(autoreverses: true)

    /// The completion pulse: one settle-and-release scale on the hero ring when a scan or clean
    /// finishes. Distinct from `ring`/`ringTrim` — those *draw* the ring; this is a single extra
    /// beat layered on top once, not a state the ring lives in.
    public static let completionPulse = Animation.spring(response: 0.4, dampingFraction: 0.55)

    /// Per-row entrance stagger for a freshly-landed result list (PLAN §5 volume-raise): each of
    /// the first `staggerCap` rows delays by one more `staggerStep`, then everything after that
    /// arrives together. Capped so a 200-row list doesn't take four seconds to finish appearing.
    public static let staggerStep: Double = 0.02
    public static let staggerCap: Int = 10
    public static func staggerDelay(_ index: Int) -> Double { Double(min(index, staggerCap)) * staggerStep }
}
