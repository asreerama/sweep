import SwiftUI
import SweepSystem
import SweepUI

/// The FDA step's live status readout.
///
/// Deliberately does not borrow `SweepTokens.tierCaution`/`tierExpert` for `.denied` — Palette v2
/// (PLAN §5) reserves amber/red exclusively for safety-tier badges, and "Full Disk Access is not
/// granted yet" is not a safety warning, it is a normal, expected state most first launches start
/// in. The three states are told apart by icon and label, not by borrowing tier semantics:
/// a spinner while checking, a plain lock while not granted, an accent-washed checkmark once
/// granted — the same "soft accent wash" success states already use elsewhere (PLAN §5
/// volume-raise).
struct CapabilityStatusChip: View {
    let status: CapabilityStatus
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: SweepTokens.s2 - 2) {
            icon
            Text(label)
                .font(SweepFont.badge)
                .tracking(0.3)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SweepTokens.s3)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(tint.opacity(status == .available ? 0.12 : 0.08))
        )
        .animation(SweepMotion.row, value: status)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12.5, height: 12.5)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var symbol: String {
        switch status {
        case .unknown: "questionmark.circle"
        case .denied: "lock"
        case .available: "checkmark.seal.fill"
        }
    }

    private var label: String {
        if isRefreshing { return "Checking\u{2026}" }
        switch status {
        case .unknown: return "Not checked yet"
        case .denied: return "Not granted"
        case .available: return "Granted"
        }
    }

    private var tint: Color {
        switch status {
        case .unknown, .denied: .secondary
        case .available: SweepTokens.accent
        }
    }
}

#Preview("Capability chip") {
    VStack(alignment: .leading, spacing: SweepTokens.s3) {
        CapabilityStatusChip(status: .unknown, isRefreshing: true)
        CapabilityStatusChip(status: .unknown, isRefreshing: false)
        CapabilityStatusChip(status: .denied, isRefreshing: false)
        CapabilityStatusChip(status: .available, isRefreshing: false)
    }
    .padding(SweepTokens.s5)
    .background(SweepTokens.ground)
}
