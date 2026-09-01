import SwiftUI

/// Right-aligned byte readout with the unit in its own left-aligned column.
///
/// One right-aligned string would line up `GB` under `MB` and leave the digits ragged, which is
/// the opposite of what a size column is for. Splitting the two puts every decimal point on the
/// same vertical, down a group and across groups, since both columns are fixed width and the
/// digits are monospaced.
public struct SizeColumn: View {
    private let value: String
    private let unit: String
    private let font: Font
    private let emphasized: Bool

    public init(value: String, unit: String, font: Font, emphasized: Bool) {
        self.value = value
        self.unit = unit
        self.font = font
        self.emphasized = emphasized
    }

    public init(byteCount: Int64, font: Font = SweepFont.mono, emphasized: Bool = false) {
        let parts = SweepFormat.split(byteCount)
        self.init(value: parts.value, unit: parts.unit, font: font, emphasized: emphasized)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .contentTransition(.numericText())
                .frame(width: SweepTokens.sizeValueWidth, alignment: .trailing)
            Text(unit)
                .frame(width: SweepTokens.sizeUnitWidth, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .frame(width: SweepTokens.sizeColumnWidth, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(unit)")
    }
}

#Preview("Size column") {
    VStack(alignment: .trailing, spacing: 2) {
        ForEach([Int64(2_830_000_000), 838_000_000, 1_050_000_000, 120_000_000, 812, 0], id: \.self) { bytes in
            SizeColumn(byteCount: bytes)
        }
    }
    .padding(SweepTokens.s5)
}
