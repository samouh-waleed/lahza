import SwiftUI

/// The top of a sheet: a native title with an optional eyebrow and subtitle, and a glass
/// close button (dismisses the sheet unless you pass `onClose`). Put it first in the sheet's
/// content and present with ``SwiftUICore/View/lzSheetPresentation(_:background:)``.
///
/// ```swift
/// .sheet(isPresented: $showFilters) {
///     VStack(spacing: 0) {
///         SheetHeader("Filters", subtitle: "Narrow your search")
///         FilterList(…)
///     }
///     .lzSheetPresentation([.medium, .large])
/// }
/// ```
public struct SheetHeader<Trailing: View>: View {
    private let title: String
    private let eyebrow: String?
    private let subtitle: String?
    private let closeLabel: String
    private let showsClose: Bool
    private let onClose: (() -> Void)?
    private let trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    public init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil, closeLabel: String = "Close", showsClose: Bool = true,
                onClose: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.eyebrow = eyebrow
        self.subtitle = subtitle
        self.closeLabel = closeLabel
        self.showsClose = showsClose
        self.onClose = onClose
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: LZSpace.md) {
            VStack(alignment: .leading, spacing: LZSpace.xs) {
                if let eyebrow {
                    Text(eyebrow).lzText(.label).foregroundStyle(.lz(.muted))
                }
                Text(title)
                    .lzText(.title)
                    .foregroundStyle(.lz(.ink))
                if let subtitle {
                    Text(subtitle).lzText(.subheadline).foregroundStyle(.lz(.muted))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            GlassEffectContainer(spacing: LZSpace.sm) {
                HStack(spacing: LZSpace.sm) {
                    trailing
                    if showsClose {
                        LZIconButton("xmark", label: closeLabel, style: .glass, size: 40) {
                            if let onClose { onClose() } else { dismiss() }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, LZLayout.gutter)
        .padding(.top, LZSpace.xl)
        .padding(.bottom, LZSpace.md)
    }
}

extension SheetHeader where Trailing == EmptyView {
    public init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil, closeLabel: String = "Close", showsClose: Bool = true,
                onClose: (() -> Void)? = nil) {
        self.init(title, eyebrow: eyebrow, subtitle: subtitle, closeLabel: closeLabel, showsClose: showsClose, onClose: onClose) { EmptyView() }
    }
}

/// What a sheet rests on.
nonisolated public enum LZSheetBackground: String, CaseIterable, Sendable {
    /// Opaque paper: for sheets that carry content (readings, lists, settings with
    /// previews). Content rests on paper, and glass controls inside never sit on glass.
    case paper
    /// The system's Liquid Glass sheet: for small control-only sheets (a picker, a few actions).
    case glass
}

extension View {
    /// Presents this sheet content with native detents, a visible grabber, and paper
    /// (default) or the system glass behind it.
    @ViewBuilder
    public func lzSheetPresentation(_ detents: Set<PresentationDetent> = [.medium, .large], background: LZSheetBackground = .paper) -> some View {
        let base = presentationDetents(detents).presentationDragIndicator(.visible)
        switch background {
        case .paper: base.presentationBackground(.lz(.surface))
        case .glass: base
        }
    }
}
