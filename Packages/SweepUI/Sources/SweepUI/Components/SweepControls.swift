import SwiftUI

// MARK: - Buttons

/// The one filled button in the app. Accent-tinted, so it belongs to the same family as the
/// ring and the results; used for the action a screen exists to perform, once per screen.
///
/// `tint` defaults to the kinetic accent. The Clean flow's confirm sheet passes
/// `SweepTokens.danger` instead: the one place a filled button represents an irreversible,
/// destructive action rather than the screen's home action, and the only other color this style
/// is allowed to carry.
public struct SweepPrimaryButtonStyle: ButtonStyle {
    private let minWidth: CGFloat
    private let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    public init(minWidth: CGFloat = 148, tint: Color = SweepTokens.accent) {
        self.minWidth = minWidth
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? .white : Color.secondary)
            .frame(minWidth: minWidth)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(.fill.tertiary))
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(SweepMotion.row, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Everything else. Bordered, neutral, no tint.
public struct SweepQuietButtonStyle: ButtonStyle {
    private let minWidth: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    public init(minWidth: CGFloat = 0) { self.minWidth = minWidth }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, SweepTokens.s3)
            .frame(minWidth: minWidth)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SweepPrimaryButtonStyle {
    public static var sweepPrimary: SweepPrimaryButtonStyle { SweepPrimaryButtonStyle() }
    public static func sweepPrimary(minWidth: CGFloat) -> SweepPrimaryButtonStyle {
        SweepPrimaryButtonStyle(minWidth: minWidth)
    }
    /// The Clean confirm sheet's primary action: same shape, `SweepTokens.danger` fill.
    public static func sweepDestructive(minWidth: CGFloat = 148) -> SweepPrimaryButtonStyle {
        SweepPrimaryButtonStyle(minWidth: minWidth, tint: SweepTokens.danger)
    }
}

extension ButtonStyle where Self == SweepQuietButtonStyle {
    public static var sweepQuiet: SweepQuietButtonStyle { SweepQuietButtonStyle() }
}

// MARK: - Screen furniture

/// Title, one-line subtitle, trailing controls. Every content screen opens with one.
public struct ScreenHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SweepTokens.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SweepFont.screenTitle)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(SweepFont.screenSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: SweepTokens.s4)
            trailing
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.top, SweepTokens.s5)
        .padding(.bottom, SweepTokens.s4)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    public init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Grouped container for rows (Palette v2): a white/elevated card on the tinted ground, separated
/// by a soft diffuse shadow in light mode and a low-contrast hairline everywhere — no hard border
/// doing all the work, no gradient, no elevation theatre.
public struct SectionCard<Content: View>: View {
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background {
                RoundedRectangle(cornerRadius: SweepTokens.cornerRadius, style: .continuous)
                    .fill(SweepTokens.cardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: SweepTokens.cornerRadius, style: .continuous)
                    .strokeBorder(SweepTokens.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: SweepTokens.cornerRadius, style: .continuous))
            .shadow(
                color: colorScheme == .dark ? .clear : SweepTokens.cardShadow,
                radius: 8, y: 2
            )
    }
}

/// The M2 read-only wall. Stated once, plainly, next to the control it disables — not as a
/// banner the user has to dismiss, and not as a tooltip they have to discover.
public struct GateNotice: View {
    private let text: String
    private let symbol: String

    public init(_ text: String = "Cleaning arrives at Gate 1", symbol: String = "lock") {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        Label {
            Text(text).font(SweepFont.caption)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.tertiary)
        .accessibilityLabel(text)
    }
}

/// Quiet, secondary explanation. Skipped roots, permission notes, honest caveats.
public struct Footnote: View {
    private let text: String
    private let symbol: String?

    public init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: SweepTokens.s1 + 2) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .regular))
            }
            Text(text).font(SweepFont.caption)
        }
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Search

/// Inline search field. `.searchable` puts the field in the toolbar, which is the wrong place
/// for a list filter that belongs to one pane of a split view.
public struct SweepSearchField: View {
    @Binding private var text: String
    private let prompt: String

    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String = "Search") {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: SweepTokens.s2 - 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SweepTokens.s2)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.fill.tertiary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1.5)
        }
        .animation(SweepMotion.row, value: isFocused)
    }
}

// MARK: - Path ticker

/// The path currently being read, in SF Mono, elided in the middle.
///
/// Fixed height and a reserved width so the layout does not twitch as paths of different
/// lengths go past — the ticker is a readout, not a marquee.
public struct PathTicker: View {
    private let path: String?
    private let width: CGFloat

    public init(path: String?, width: CGFloat = 460) {
        self.path = path
        self.width = width
    }

    public var body: some View {
        Text(path ?? " ")
            .font(SweepFont.monoSmall)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, height: 13, alignment: .center)
            .opacity(path == nil ? 0 : 1)
            .accessibilityHidden(true)
    }
}

#Preview("Controls") {
    VStack(alignment: .leading, spacing: SweepTokens.s4) {
        HStack(spacing: SweepTokens.s3) {
            Button("Scan") {}.buttonStyle(.sweepPrimary)
            Button("Clean") {}.buttonStyle(.sweepPrimary).disabled(true)
            Button("Rescan") {}.buttonStyle(.sweepQuiet)
        }
        GateNotice()
        Footnote("2 locations skipped: no permission to read them.", symbol: "info.circle")
        StatefulSearchPreview()
        PathTicker(path: "~/Library/Caches/Google/Chrome/Default/Cache/Cache_Data/f_0002a1")
        SectionCard {
            InventoryRow(symbol: "trash", title: "System Junk", detail: "18,204 items",
                         detailIsPath: false, sizeValue: "9.81", sizeUnit: "GB",
                         tier: .safe, emphasis: .summary)
            Divider()
            InventoryRow(symbol: "hammer", title: "Developer", detail: "2,133 items",
                         detailIsPath: false, sizeValue: "2.44", sizeUnit: "GB",
                         tier: .caution, emphasis: .summary)
        }
    }
    .padding(SweepTokens.s5)
    .frame(width: 560)
}

private struct StatefulSearchPreview: View {
    @State private var text = ""
    var body: some View { SweepSearchField(text: $text).frame(width: 220) }
}
