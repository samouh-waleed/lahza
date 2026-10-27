import SwiftUI

/// Progress in the house style. Use it as a `ProgressViewStyle` so VoiceOver gets the system's
/// progress semantics:
///
/// ```swift
/// ProgressView(value: indexed, total: 1) { Text("Preparing your library") }
///     .progressViewStyle(.dd(.horizon))
/// ```
///
/// An indeterminate `ProgressView()` with this style shows the rising-sun loader, never a bare
/// spinner.
public struct DDProgressStyle: ProgressViewStyle {
    public enum Kind: String, CaseIterable, Sendable {
        /// A 6 pt capsule bar.
        case bar
        /// A thin horizon line that fills like dawn, with a glowing leading edge (onboarding).
        case horizon
        /// A ring (counts, repetitions).
        case ring
    }

    public var kind: Kind

    public init(_ kind: Kind = .bar) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        DDProgressBody(kind: kind, fraction: configuration.fractionCompleted, label: configuration.label, current: configuration.currentValueLabel)
    }
}

extension ProgressViewStyle where Self == DDProgressStyle {
    public static func dd(_ kind: DDProgressStyle.Kind = .bar) -> DDProgressStyle { DDProgressStyle(kind) }
}

struct DDProgressBody<Label: View, Current: View>: View {
    let kind: DDProgressStyle.Kind
    let fraction: Double?
    let label: Label?
    let current: Current?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: DDSpace.sm) {
            if kind != .ring, let label {
                label.ddText(.subheadline).foregroundStyle(.dd(.ink))
            }
            if let fraction {
                switch kind {
                case .bar: bar(fraction)
                case .horizon: horizon(fraction)
                case .ring: ring(fraction)
                }
            } else {
                DDLoader(.sun, size: kind == .ring ? ringSize : 28, label: "")
                    .frame(maxWidth: kind == .ring ? nil : .infinity, alignment: .center)
            }
            if kind != .ring, let current {
                current.ddText(.caption).foregroundStyle(.dd(.muted))
            }
        }
        .animation(DDMotionToken.interface.animation(reduceMotion: reduceMotion), value: fraction)
    }

    private func bar(_ value: Double) -> some View {
        Capsule(style: .continuous)
            .fill(.dd(.surface2))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(.dd(.accent))
                        .frame(width: max(6, proxy.size.width * clamp(value)))
                        .opacity(value > 0 ? 1 : 0)
                }
            }
            .frame(height: 6)
    }

    private func horizon(_ value: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width * clamp(value)
            ZStack(alignment: .leading) {
                Capsule().fill(.dd(.line)).frame(height: 2)
                Capsule()
                    .fill(LinearGradient(colors: [Color.dd(.gold).opacity(0.35), Color.dd(.gold)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, width), height: 3)
                // The rising light at the leading edge.
                Circle()
                    .fill(RadialGradient(colors: [Color.dd(.gold), Color.dd(.gold).opacity(0)], center: .center, startRadius: 0, endRadius: 9))
                    .frame(width: 18, height: 18)
                    .offset(x: width - 9)
                    .opacity(value > 0 && value < 1 ? 1 : 0)
            }
            .frame(height: 18)
        }
        .frame(height: 18)
    }

    private func ring(_ value: Double) -> some View {
        ZStack {
            Circle().stroke(.dd(.surface2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: clamp(value))
                .stroke(.dd(.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let current {
                current.font(.dd(.caption).weight(.semibold).monospacedDigit()).foregroundStyle(.dd(.ink))
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    private func clamp(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, v))) }
}
