import Observation
import SwiftUI

/// One toast.
public struct DDToast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var systemImage: String?

    public init(_ message: String, systemImage: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
    }
}

/// The toast queue: at most three visible, each for 2.5 s, newest at the bottom of the stack.
/// Showing a fourth retires the oldest. Toasts are announced to VoiceOver.
///
/// Install once with ``SwiftUICore/View/ddToastHost(_:)``; views then read it with
/// `@Environment(DDToastCenter.self)`.
@MainActor @Observable public final class DDToastCenter {
    public static let maxVisible = 3
    public static let lifetime: Duration = .milliseconds(2_500)

    public private(set) var toasts: [DDToast] = []

    private let lifetime: Duration
    private let announce: Bool
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - lifetime: how long each toast stays (tests shorten it).
    ///   - announce: post a VoiceOver announcement for each toast.
    public init(lifetime: Duration = DDToastCenter.lifetime, announce: Bool = true) {
        self.lifetime = lifetime
        self.announce = announce
    }

    /// Shows a toast ("Saved").
    @discardableResult
    public func show(_ message: String, systemImage: String? = nil) -> DDToast {
        let toast = DDToast(message, systemImage: systemImage)
        toasts.append(toast)
        while toasts.count > Self.maxVisible {
            let retired = toasts.removeFirst()
            timers.removeValue(forKey: retired.id)?.cancel()
        }
        let lifetime = lifetime
        timers[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
        if announce {
            AccessibilityNotification.Announcement(message).post()
        }
        return toast
    }

    public func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }

    public func dismissAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        toasts.removeAll()
    }
}

extension View {
    /// Hosts toasts at the top of this view (safe area + 8) and injects the center into the
    /// environment.
    public func ddToastHost(_ center: DDToastCenter) -> some View {
        environment(center)
            .overlay(alignment: .top) { DDToastStack(center: center) }
    }
}

struct DDToastStack: View {
    let center: DDToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DDSpace.sm) {
            ForEach(center.toasts) { toast in
                DDToastView(toast: toast) { center.dismiss(toast.id) }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -DDSpace.md)).animation(.easeOut(duration: 0.22)),
                        removal: .opacity.animation(.easeIn(duration: 0.16))
                    ))
            }
        }
        .padding(.top, DDSpace.sm)
        .padding(.horizontal, DDLayout.gutter)
        .animation(reduceMotion ? .easeInOut(duration: DDMotion.reducedFade) : DDMotionToken.interface.animation, value: center.toasts)
    }
}

/// The toast pill: ink paper with paper-coloured text and a floating lift (not glass: it is a
/// message, not a control).
struct DDToastView: View {
    let toast: DDToast
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: DDSpace.sm) {
                if let systemImage = toast.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.dd(.bg))
                        .accessibilityHidden(true)
                }
                Text(toast.message)
                    .ddText(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.dd(.bg))
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, DDSpace.lg + 2)
            .padding(.vertical, DDSpace.md)
            .frame(minHeight: DDHitTarget.comfortable)
            .background(.dd(.ink), in: Capsule(style: .continuous))
            .ddElevation(.float)
        }
        .buttonStyle(DDPressStyle())
        .accessibilityLabel(toast.message)
        .accessibilityHint("Double-tap to dismiss")
    }
}
