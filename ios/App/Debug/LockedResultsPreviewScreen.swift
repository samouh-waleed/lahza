#if DEBUG
import LZBilling
import LZDesign
import SwiftUI

/// Settings › Developer › Locked results (`-LZRoute locked-results`): the "N more from earlier years"
/// row as a free search will end, for review in both appearances and at every text size. Ask places
/// it after its results once search lands.
struct LockedResultsPreviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.lg) {
                Text("How a free search ends when older photos also match. Tap a row to open the unlock.")
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.muted))
                LockedResultsRow(count: 2_431)
                LockedResultsRow(count: 1)
                if model.entitlement.isUnlocked {
                    Notice(.info, message: "The full library is unlocked, so searches have no locked results and the row is hidden.")
                }
            }
            .lzPage()
            .padding(.vertical, LZSpace.lg)
        }
        .background(.lz(.bg))
        .navigationTitle("Locked results")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("locked-results-preview")
    }
}
#endif
