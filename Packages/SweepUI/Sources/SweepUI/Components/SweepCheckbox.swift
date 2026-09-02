import SwiftUI

/// Tri-state checkbox.
///
/// Drawn rather than borrowed from `.toggleStyle(.checkbox)` for one reason: a group header
/// has to show "some of this group is selected", and AppKit's mixed state has no SwiftUI
/// spelling. Having two visually different checkboxes in the same list is worse than drawing
/// one. It uses `Color.accentColor` — the *system* accent the user picked, not the Sweep
/// kinetic accent, which stays reserved for progress and results.
public struct SweepCheckbox: View {
    private let state: SelectionState
    private let label: String
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    public init(state: SelectionState, label: String, action: @escaping () -> Void) {
        self.state = state
        self.label = label
        self.action = action
    }

    public init(isOn: Bool, label: String, action: @escaping () -> Void) {
        self.init(state: isOn ? .all : .none, label: label, action: action)
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
                if state != .none {
                    Image(systemName: state == .all ? "checkmark" : "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(SweepMotion.row, value: state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(state == .all ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        state == .none ? Color(nsColor: .controlColor) : Color.accentColor
    }

    private var border: Color {
        state == .none ? Color(nsColor: .separatorColor) : .clear
    }

    private var accessibilityValue: String {
        switch state {
        case .none: "unselected"
        case .partial: "partially selected"
        case .all: "selected"
        }
    }
}

#Preview("Checkbox states") {
    HStack(spacing: SweepTokens.s4) {
        SweepCheckbox(state: .none, label: "none") {}
        SweepCheckbox(state: .partial, label: "partial") {}
        SweepCheckbox(state: .all, label: "all") {}
        SweepCheckbox(state: .all, label: "disabled") {}.disabled(true)
    }
    .padding(SweepTokens.s5)
}
