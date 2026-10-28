import Observation
import SwiftUI

/// One toast.
public struct LZToast: Identifiable, Equatable, Sendable {
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
/// Install once with ``SwiftUICore/View/lzToastHost(_:)``; views then read it with
/// `@Environment(LZToastCenter.self)`.
@MainActor @Observable public final class LZToastCenter {
    public static let maxVisible = 3
    public static let lifetime: Duration = .milliseconds(2_500)

    public private(set) var toasts: [LZToast] = []

    private let lifetime: Duration
    private let announce: Bool
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - lifetime: how long each toast stays (tests shorten it).
    ///   - announce: post a VoiceOver announcement for each toast.
    public init(lifetime: Duration = LZToastCenter.lifetime, announce: Bool = true) {
        self.lifetime = lifetime
        self.announce = announce
    }

    /// Shows a toast ("Saved").
    @discardableResult
    public func show(_ message: String, systemImage: String? = nil) -> LZToast {
        let toast = LZToast(message, systemImage: systemImage)
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
    public func lzToastHost(_ center: LZToastCenter) -> some View {
        environment(center)
            .overlay(alignment: .top) { LZToastStack(center: center) }
    }
}

struct LZToastStack: View {
    let center: LZToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: LZSpace.sm) {
            ForEach(center.toasts) { toast in
                LZToastView(toast: toast) { center.dismiss(toast.id) }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -LZSpace.md)).animation(.easeOut(duration: 0.22)),
                        removal: .opacity.animation(.easeIn(duration: 0.16))
                    ))
            }
        }
        .padding(.top, LZSpace.sm)
        .padding(.horizontal, LZLayout.gutter)
        .animation(reduceMotion ? .easeInOut(duration: LZMotion.reducedFade) : LZMotionToken.interface.animation, value: center.toasts)
    }
}

/// The toast pill: ink paper with paper-coloured text and a floating lift (not glass: it is a
/// message, not a control).
struct LZToastView: View {
    let toast: LZToast
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: LZSpace.sm) {
                if let systemImage = toast.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.lz(.bg))
                        .accessibilityHidden(true)
                }
                Text(toast.message)
                    .lzText(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.lz(.bg))
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, LZSpace.lg + 2)
            .padding(.vertical, LZSpace.md)
            .frame(minHeight: LZHitTarget.comfortable)
            .background(.lz(.ink), in: Capsule(style: .continuous))
            .lzElevation(.float)
        }
        .buttonStyle(LZPressStyle())
        .accessibilityLabel(toast.message)
        .accessibilityHint("Double-tap to dismiss")
    }
}
