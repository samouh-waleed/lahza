import SwiftUI

/// The system segmented picker supplies native selection, focus and Liquid Glass behavior.
/// At accessibility text sizes, full-width choices keep every label readable and tappable.
public struct LZSegmented<ID: Hashable & Sendable>: View {
    private let label: String
    private let options: [LZChipOption<ID>]
    @Binding private var selection: ID
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ label: String, options: [LZChipOption<ID>], selection: Binding<ID>) {
        self.label = label
        self.options = options
        _selection = selection
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: LZSpace.xs) {
                    ForEach(options) { option in
                        accessibleOption(option)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
            } else {
                Picker(label, selection: $selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .frame(minHeight: LZHitTarget.comfortable)
            }
        }
        .lzHaptic(.selection, trigger: selection)
    }

    private func accessibleOption(_ option: LZChipOption<ID>) -> some View {
        let selected = option.id == selection
        let shape = RoundedRectangle(cornerRadius: LZRadius.control, style: .continuous)
        return Button {
            selection = option.id
        } label: {
            HStack(spacing: LZSpace.md) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(option.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .lzText(.body)
            .foregroundStyle(selected ? .lz(.accent) : .lz(.ink))
            .padding(LZSpace.md)
            .frame(minHeight: LZHitTarget.comfortable)
            .background(selected ? .lz(.accentSoft) : .lz(.surface2), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(LZPressStyle(scale: 1))
        .lzFocusRing(shape)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
