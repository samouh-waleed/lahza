import LZDesign
import LZIndex
import SwiftUI

/// Ask while the index is first built: how far reading has got, then the grouping into moments and trips.
struct IndexingCard: View {
    let phase: IndexStatus.Phase

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                HStack(alignment: .center, spacing: LZSpace.md) {
                    IconBadge("photo.stack", tone: .accent)
                    Text(AskCopy.indexingTitle(phase))
                        .lzText(.headline)
                        .foregroundStyle(.lz(.ink))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .reading(let done, let total) = phase, total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total)) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(AskCopy.readProgress(done: done, total: total))
                    }
                    .progressViewStyle(.lz(.bar))
                    .accessibilityLabel(AskCopy.indexingTitle(phase))
                } else {
                    ProgressView()
                        .progressViewStyle(.lz(.bar))
                        .accessibilityLabel(AskCopy.indexingTitle(phase))
                }
                Text(AskCopy.indexingCaption(phase))
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-indexing")
    }
}

/// Ask once the index is built: the library at a glance and what search covers.
struct LibrarySummaryCard: View {
    let summary: LibrarySummary
    var isLimited = false

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                Text(AskCopy.summaryEyebrow)
                    .lzText(.label)
                    .foregroundStyle(.lz(.muted))
                HStack(alignment: .firstTextBaseline, spacing: LZSpace.sm) {
                    LZNumeral(summary.assets.formatted(), role: .numeral)
                        .foregroundStyle(.lz(.ink))
                    Text(AskCopy.assetsNoun(summary.assets, isLimited: isLimited))
                        .lzText(.body)
                        .foregroundStyle(.lz(.muted))
                }
                if let structure = AskCopy.structure(summary) {
                    Text(structure)
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.ink))
                }
                if let located = AskCopy.located(summary) {
                    Text(located)
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.muted))
                }
                Text(AskCopy.capability)
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
                    .padding(.top, LZSpace.xs)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask-library-summary")
    }
}
