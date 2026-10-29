import LZDesign
import LZSearch
import SwiftUI

/// What a search found, at a glance: progress while it runs, then the counts and sections, or why nothing matched.
/// A stand-in until the full results view (moment cards, chips, widening taps) replaces it.
struct SearchStatusCard: View {
    let state: SearchStore.State

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .understanding, .searching:
            progress(AskCopy.searching)
        case .lookingUpPlace(let name):
            progress(AskCopy.lookingUp(name))
        case .results(let result):
            PaperCard {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    LZAdaptiveStack(spacing: LZSpace.sm, verticalAlignment: .firstTextBaseline) {
                        LZNumeral(result.totals.moments.formatted(), role: .numeral)
                            .foregroundStyle(.lz(.ink))
                        Text(result.totals.moments == 1 ? "moment" : "moments")
                            .lzText(.body)
                            .foregroundStyle(.lz(.muted))
                    }
                    Text(MomentCopy.counts(photos: result.totals.photos, videos: result.totals.videos))
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.ink))
                    ForEach(result.sections) { section in
                        Text("\(section.title) · \(section.groups.flatMap(\.cards).count.formatted())")
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.muted))
                    }
                    Text(result.coverage.caption)
                        .lzText(.caption)
                        .foregroundStyle(.lz(.muted))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ask-results")
            if let notice = result.unsupportedNotice { Notice(.info, message: notice) }
        case .noMatch(let result):
            if let noMatch = result.noMatch {
                EmptyState(noMatch.headline, message: noMatch.detail ?? "", systemImage: "magnifyingglass")
                    .accessibilityIdentifier("ask-no-match")
            }
        case .failed(let message):
            Notice(.warn, message: message)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: LZSpace.sm) {
            ProgressView()
            Text(text)
                .lzText(.subheadline)
                .foregroundStyle(.lz(.muted))
        }
        .accessibilityElement(children: .combine)
    }
}
