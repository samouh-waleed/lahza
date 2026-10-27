import SwiftUI

/// The skeleton's slow light sweep (pure, host-tested): a 1.7 s ease-in-out pass followed by a
/// rest, so the page never flickers.
nonisolated public enum DDSkeletonSweep {
    public static let sweep: TimeInterval = 1.7
    public static let rest: TimeInterval = 0.9
    public static var cycle: TimeInterval { sweep + rest }

    /// The band's centre across the width (−0.35…1.35), or nil while resting.
    public static func position(at time: TimeInterval) -> Double? {
        let t = time.truncatingRemainder(dividingBy: cycle)
        guard t < sweep else { return nil }
        return -0.35 + 1.7 * DDLoaderPhase.ease(t / sweep)
    }
}

extension View {
    /// Shows this view as a skeleton while `active`: its text and images become soft paper
    /// placeholders with a slow light sweep. The sweep pauses off screen, in the background and
    /// under Reduce Motion. VoiceOver hears one "Loading" element.
    public func ddSkeleton(_ active: Bool, label: String = "Loading") -> some View {
        modifier(DDSkeletonModifier(active: active, label: label))
    }
}

struct DDSkeletonModifier: ViewModifier {
    let active: Bool
    let label: String

    func body(content: Content) -> some View {
        if active {
            content
                .redacted(reason: .placeholder)
                .foregroundStyle(.dd(.muted))
                .overlay {
                    DDSweep()
                        .mask { content.redacted(reason: .placeholder) }
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .ddDecorativeRegion()
        } else {
            content
        }
    }
}

/// A block placeholder (image wells, cards) with the sweep.
public struct SkeletonBlock: View {
    private let height: CGFloat?
    private let radius: CGFloat

    public init(height: CGFloat? = nil, radius: CGFloat = DDRadius.sm) {
        self.height = height
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(.dd(.ink, opacity: 0.1))
            .overlay { DDSweep().clipShape(shape) }
            .frame(height: height)
            .accessibilityHidden(true)
            .ddDecorativeRegion()
    }
}

/// Lines of placeholder text: full-width lines and a shorter last line.
public struct SkeletonText: View {
    private let lines: Int
    private let role: DDTextRole
    @ScaledMetric private var lineHeight: CGFloat

    public init(lines: Int = 3, role: DDTextRole = .body) {
        self.lines = max(1, lines)
        self.role = role
        _lineHeight = ScaledMetric(wrappedValue: role.spec.size, relativeTo: role.spec.textStyle)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: lineHeight * 0.55) {
            ForEach(0..<lines, id: \.self) { index in
                let fraction: CGFloat = index == lines - 1 && lines > 1 ? 0.62 : 1
                Color.clear
                    .frame(height: lineHeight * 0.72)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            SkeletonBlock(height: lineHeight * 0.72, radius: lineHeight * 0.36)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// The moving highlight.
struct DDSweep: View {
    @Environment(\.ddStatusMotionAllowed) private var allowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !allowed)) { context in
                GeometryReader { proxy in
                    if let position = DDSkeletonSweep.position(at: context.date.timeIntervalSinceReferenceDate) {
                        let band = max(80, proxy.size.width * 0.42)
                        LinearGradient(colors: [.clear, highlight, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .rotationEffect(.degrees(12))
                            .frame(height: proxy.size.height * 2)
                            .position(x: proxy.size.width * position, y: proxy.size.height / 2)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var highlight: Color {
        scheme == .dark ? DDRGBA(hex: 0xF7F1EA, alpha: 0.10).color : DDRGBA(hex: 0xFFFDFA, alpha: 0.75).color
    }
}
