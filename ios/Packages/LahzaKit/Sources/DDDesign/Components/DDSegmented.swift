import SwiftUI

/// The system segmented picker supplies native selection, focus and Liquid Glass behavior.
/// At accessibility text sizes, full-width choices keep every label readable and tappable.
public struct DDSegmented<ID: Hashable & Sendable>: View {
    private let label: String
    private let options: [DDChipOption<ID>]
    @Binding private var selection: ID
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ label: String, options: [DDChipOption<ID>], selection: Binding<ID>) {
        self.label = label
        self.options = options
        _selection = selection
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: DDSpace.xs) {
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
                .frame(minHeight: DDHitTarget.comfortable)
            }
        }
        .ddHaptic(.selection, trigger: selection)
    }

    private func accessibleOption(_ option: DDChipOption<ID>) -> some View {
        let selected = option.id == selection
        let shape = RoundedRectangle(cornerRadius: DDRadius.control, style: .continuous)
        return Button {
            selection = option.id
        } label: {
            HStack(spacing: DDSpace.md) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(option.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .ddText(.body)
            .foregroundStyle(selected ? .dd(.accent) : .dd(.ink))
            .padding(DDSpace.md)
            .frame(minHeight: DDHitTarget.comfortable)
            .background(selected ? .dd(.accentSoft) : .dd(.surface2), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(DDPressStyle(scale: 1))
        .ddFocusRing(shape)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
