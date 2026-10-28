import SwiftUI

/// Counts characters against a limit the way the backend validates them (JS `length`, UTF-16
/// code units), so the counter never says "fits" for text the server rejects.
nonisolated public struct LZCharacterCounter: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case normal
        /// Within 10 % of the limit (at least 10 characters).
        case near
        case over
    }

    public var count: Int
    public var limit: Int

    public init(text: String, limit: Int) {
        count = text.utf16.count
        self.limit = max(0, limit)
    }

    public init(count: Int, limit: Int) {
        self.count = max(0, count)
        self.limit = max(0, limit)
    }

    public var state: State {
        if count > limit { return .over }
        if count >= limit - max(10, limit / 10) { return .near }
        return .normal
    }

    public var remaining: Int { limit - count }
    /// "12/280".
    public var text: String { "\(count)/\(limit)" }
    /// "12 of 280 characters", or "12 characters over the 280 limit".
    public var accessibilityText: String {
        count > limit ? "\(count - limit) characters over the \(limit) limit" : "\(count) of \(limit) characters"
    }
}

/// A labelled paper field: single line or multiline, with helper text, a gentle error and an
/// optional counter. Focus draws an accent border; disabled fields recess.
public struct LZTextField: View {
    private let label: String
    @Binding private var text: String
    private let prompt: String?
    private let helper: String?
    private let error: String?
    private let limit: Int?
    private let multiline: Bool
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ label: String, text: Binding<String>, prompt: String? = nil, helper: String? = nil, error: String? = nil,
                limit: Int? = nil, multiline: Bool = false) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.helper = helper
        self.error = error
        self.limit = limit
        self.multiline = multiline
    }

    public var body: some View {
        let counter = limit.map { LZCharacterCounter(text: text, limit: $0) }
        let shape = RoundedRectangle(cornerRadius: LZRadius.control, style: .continuous)
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            Text(label)
                .lzText(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.lz(.ink))
                .accessibilityHidden(true)
            box(counter: counter, shape: shape)
            footer(counter)
        }
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func box(counter: LZCharacterCounter?, shape: RoundedRectangle) -> some View {
        let fill: LZColorStyle = isEnabled ? .lz(.surface) : .lz(.surface2)
        let emphasised = focused || error != nil
        let value: String = counter.map { text + ", " + $0.accessibilityText } ?? text
        return field
            .lzText(.body)
            .foregroundStyle(.lz(.ink))
            .tint(Color.lz(.accent))
            .focused($focused)
            .padding(.horizontal, LZSpace.lg)
            .padding(.vertical, multiline ? LZSpace.md + 2 : LZSpace.sm)
            .frame(minHeight: multiline ? 120 : 56, alignment: multiline ? .topLeading : .leading)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(borderStyle, lineWidth: emphasised ? 1.5 : 1) }
            .contentShape(shape)
            .onTapGesture { focused = true }
            .lzAnimation(.interface, value: focused)
            .accessibilityLabel(label)
            .accessibilityHint(error ?? helper ?? "")
            .accessibilityValue(value)
    }

    @ViewBuilder
    private var field: some View {
        if multiline {
            TextField("", text: $text, prompt: prompt.map { Text($0).foregroundStyle(.lz(.muted)) }, axis: .vertical)
                .lineLimit(4...12)
        } else {
            TextField("", text: $text, prompt: prompt.map { Text($0).foregroundStyle(.lz(.muted)) })
                .lineLimit(1)
        }
    }

    private var borderStyle: LZColorStyle {
        if error != nil { return .lz(.danger) }
        if focused { return .lz(.accent) }
        return .lz(.lineSolid)
    }

    @ViewBuilder
    private func footer(_ counter: LZCharacterCounter?) -> some View {
        if error != nil || helper != nil || counter != nil {
            HStack(alignment: .firstTextBaseline, spacing: LZSpace.sm) {
                if let error {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.lz(.dangerText))
                } else if let helper {
                    Text(helper).foregroundStyle(.lz(.muted))
                }
                Spacer(minLength: LZSpace.sm)
                if let counter {
                    Text(counter.text)
                        .monospacedDigit()
                        .foregroundStyle(counter.state == .over ? .lz(.dangerText) : (counter.state == .near ? .lz(.goldText) : .lz(.muted)))
                        .accessibilityHidden(true)
                }
            }
            .lzText(.caption)
        }
    }
}
