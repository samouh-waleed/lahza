import LZBilling
import LZDesign
import SwiftUI

/// The row a free search shows after its results when photos older than the free
/// ``Brand/Limits/freeSearchMonths`` months also match: "2,431 more from earlier years · Unlock".
/// A tap opens the paywall. It hides itself once the full library is unlocked or when nothing older
/// matched, so a results list can always place it last.
struct LockedResultsRow: View {
    /// Matches older than the free window (the search's locked count).
    let count: Int
    @Environment(AppModel.self) private var model

    /// Whether a search with `lockedCount` older matches shows the row.
    static func isShown(lockedCount: Int, isUnlocked: Bool) -> Bool { lockedCount > 0 && !isUnlocked }

    var body: some View {
        if Self.isShown(lockedCount: count, isUnlocked: model.entitlement.isUnlocked) {
            PaperCard(style: .raised, action: { model.open(.paywall) }) {
                LZAdaptiveStack(spacing: LZSpace.md) {
                    HStack(spacing: LZSpace.md) {
                        IconBadge("lock", tone: .accent, size: 36)
                        VStack(alignment: .leading, spacing: LZSpace.xxs) {
                            Text(BillingCopy.moreFromEarlierYears(count)).lzText(.headline).foregroundStyle(.lz(.ink))
                            Text(BillingCopy.lockedResultsDetail).lzText(.subheadline).foregroundStyle(.lz(.muted))
                        }
                    }
                    Spacer(minLength: 0)
                    Pill(BillingCopy.lockedResultsAction, systemImage: "lock.open", tone: .accent)
                }
            }
            .accessibilityLabel(BillingCopy.moreFromEarlierYearsLabel(count))
            .accessibilityHint(BillingCopy.lockedResultsHint)
            .accessibilityIdentifier("locked-results")
        }
    }
}
