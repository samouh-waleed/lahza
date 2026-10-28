import SwiftUI

/// An inline message on a pastel wash. Gentle by design: errors say what happened and what to
/// do, on a soft rose wash, never a red alarm. Errors are announced to VoiceOver when they appear.
public struct Notice: View {
    public enum Kind: String, CaseIterable, Sendable {
        case info, success, warn, error

        var wash: DDColorToken {
            switch self {
            case .info: .lilac
            case .success: .mint
            case .warn: .butter
            case .error: .dangerSoft
            }
        }

        var tone: DDTone {
            switch self {
            case .info: .neutral
            case .success: .sage
            case .warn: .gold
            case .error: .danger
            }
        }

        var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warn: "exclamationmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    private let kind: Kind
    private let title: String?
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ kind: Kind, title: String? = nil, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DDRadius.control, style: .continuous)
        // At accessibility sizes the icon sits above the message so the text keeps the width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DDSpace.sm))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DDSpace.md))
        layout {
            Image(systemName: kind.systemImage)
                .font(.dd(.headline))
                .foregroundStyle(.dd(kind.tone.foreground))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DDSpace.xs) {
                if let title {
                    Text(title).ddText(.headline).foregroundStyle(.dd(.ink))
                }
                Text(message).ddText(.subheadline).foregroundStyle(.dd(.ink))
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.dd(.subheadline).weight(.semibold))
                        .foregroundStyle(.dd(.accent))
                        .buttonStyle(DDPressStyle(scale: 1))
                        .frame(minHeight: DDHitTarget.minimum)
                        .ddFocusRing(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DDSpace.lg + 2)
        .background(.dd(kind.wash), in: shape)
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(.dd(kind.tone.solid), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            if kind == .error {
                AccessibilityNotification.Announcement(accessibilityText).post()
            }
        }
    }

    private var accessibilityText: String {
        let prefix = kind == .error ? "Error. " : (kind == .warn ? "Note. " : "")
        return prefix + [title, message].compactMap { $0 }.joined(separator: ". ")
    }
}

/// A calm empty state: a tone badge (or your own art), a serif title and a short, hopeful line,
/// with an optional action.
public struct EmptyState<Art: View>: View {
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let art: Art

    public init(_ title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, @ViewBuilder art: () -> Art) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.art = art()
    }

    public var body: some View {
        VStack(spacing: DDSpace.lg) {
            art
            VStack(spacing: DDSpace.sm) {
                Text(title)
                    .ddText(.displaySmall)
                    .foregroundStyle(.dd(.ink))
                    .multilineTextAlignment(.center)
                Text(message)
                    .ddText(.body)
                    .foregroundStyle(.dd(.muted))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                DDButton(actionTitle, role: .secondary, action: action)
                    .padding(.top, DDSpace.xs)
            }
        }
        .padding(.vertical, DDSpace.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Art == IconBadge {
    public init(_ title: String, message: String, systemImage: String, tone: DDTone = .accent, actionTitle: String? = nil,
                action: (() -> Void)? = nil) {
        self.init(title, message: message, actionTitle: actionTitle, action: action) {
            IconBadge(systemImage, tone: tone, size: 56)
        }
    }
}
