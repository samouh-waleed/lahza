import SwiftUI

/// Page geometry: gutters, reading margins, content widths and the iPad-adaptive rules.
nonisolated public enum DDLayout {
    /// Page side gutter on iPhone.
    public static let gutter: CGFloat = 24
    /// Page side gutter on regular-width layouts (iPad).
    public static let regularGutter: CGFloat = 40
    /// Gutter on very narrow screens (iPhone SE in Display Zoom).
    public static let compactGutter: CGFloat = 20
    /// Reader side margins: a touch wider than the page, like a book.
    public static let readingMargin: CGFloat = 28
    /// The widest a column of UI content gets.
    public static let maxContentWidth: CGFloat = 640
    /// The widest a reading column gets (about 66 characters of 21 pt Newsreader).
    public static let maxReadingWidth: CGFloat = 620
    /// Gap between a page's sections.
    public static let sectionGap: CGFloat = DDSpace.xl
    /// The horizon: the golden-ratio line hero content sits above.
    public static let horizon: CGFloat = 0.62
}

/// The layout decisions for a container: gutter, columns and stacking, from its width, size
/// class and Dynamic Type size. Pure, so it is unit-tested.
nonisolated public struct DDLayoutMetrics: Sendable, Hashable {
    public var width: CGFloat
    public var isRegularWidth: Bool
    public var isAccessibilitySize: Bool

    public init(width: CGFloat, isRegularWidth: Bool, isAccessibilitySize: Bool) {
        self.width = width
        self.isRegularWidth = isRegularWidth
        self.isAccessibilitySize = isAccessibilitySize
    }

    /// Side gutter for the page.
    public var gutter: CGFloat {
        if isRegularWidth && width >= 700 { return DDLayout.regularGutter }
        return width < 360 ? DDLayout.compactGutter : DDLayout.gutter
    }

    /// The content column's width (never wider than ``DDLayout/maxContentWidth`` unless there are
    /// columns).
    public var contentWidth: CGFloat {
        let available = max(0, width - gutter * 2)
        return columns > 1 ? available : min(available, DDLayout.maxContentWidth)
    }

    /// Card columns: two on a wide iPad (not at accessibility sizes, where cards need the width).
    public var columns: Int {
        guard isRegularWidth, !isAccessibilitySize else { return 1 }
        return width >= 1_100 ? 3 : (width >= 700 ? 2 : 1)
    }

    /// Side-by-side content (icon + text + trailing value) should stack vertically.
    public var stacksRows: Bool { isAccessibilitySize }
}

extension View {
    /// Page layout: gutters and a centred, width-capped column.
    public func ddPage(maxWidth: CGFloat = DDLayout.maxContentWidth) -> some View {
        modifier(DDPageModifier(maxWidth: maxWidth, reading: false))
    }

    /// Reading layout: book margins and a centred reading column.
    public func ddReadingColumn() -> some View {
        modifier(DDPageModifier(maxWidth: DDLayout.maxReadingWidth, reading: true))
    }
}

struct DDPageModifier: ViewModifier {
    let maxWidth: CGFloat
    let reading: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        let gutter = reading ? DDLayout.readingMargin : (sizeClass == .regular ? DDLayout.regularGutter : DDLayout.gutter)
        content
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, gutter)
            .frame(maxWidth: .infinity)
    }
}

/// An `HStack` that becomes a `VStack` at accessibility text sizes (or always, when `vertical`).
public struct DDAdaptiveStack<Content: View>: View {
    private let spacing: CGFloat
    private let horizontalAlignment: HorizontalAlignment
    private let verticalAlignment: VerticalAlignment
    private let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(spacing: CGFloat = DDSpace.md, horizontalAlignment: HorizontalAlignment = .leading,
                verticalAlignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.content = content()
    }

    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}

/// Cards in columns: one on iPhone, two or three on a wide iPad.
public struct DDColumns<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    public init(spacing: CGFloat = DDSpace.lg, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        let metrics = DDLayoutMetrics(width: width, isRegularWidth: sizeClass == .regular, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: max(1, metrics.columns))
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Wraps items onto as many lines as they need (chip groups).
public struct DDFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = DDSpace.sm, lineSpacing: CGFloat = DDSpace.sm) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = Self.measure(subviews, maxWidth: maxWidth)
        let result = DDFlowMath.arrange(sizes: sizes, maxWidth: maxWidth, spacing: spacing, lineSpacing: lineSpacing)
        // Fill the offered width so items start at the leading edge wherever the flow is placed.
        return CGSize(width: maxWidth.isFinite ? maxWidth : result.size.width, height: result.size.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.measure(subviews, maxWidth: bounds.width)
        let result = DDFlowMath.arrange(sizes: sizes, maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            let size = sizes[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
        }
    }
}

extension DDFlowLayout {
    /// Each item's natural size, but never wider than a line (so its text wraps at large sizes).
    static func measure(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            guard natural.width > maxWidth, maxWidth.isFinite else { return natural }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }
}

/// Flow layout maths (host-tested).
nonisolated enum DDFlowMath {
    struct Result: Equatable {
        var origins: [CGPoint]
        var size: CGSize
    }

    static func arrange(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> Result {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for size in sizes {
            let width = min(size.width, maxWidth)
            if x > 0 && x + width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return Result(origins: origins, size: CGSize(width: widest, height: sizes.isEmpty ? 0 : y + lineHeight))
    }
}
