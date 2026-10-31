import LZBilling
import LZCore
import LZDesign
import SwiftUI

struct SettingsHomeScreen: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    /// Persists `LZFakeStore`, which ``DebugLaunch`` reads at the next launch (launch arguments win).
    @AppStorage("LZFakeStore") private var sampleStorePrices = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make it yours.").lzText(.displayLarge)
                    Text("Your settings stay on this iPhone.").lzText(.body).foregroundStyle(.lz(.muted))
                }
                .padding(.bottom, 8)
                group("PLAN") {
                    row(BillingCopy.productName, "sparkles", .fullLibrary, value: BillingCopy.settingsValue(isUnlocked: model.entitlement.isUnlocked))
                        .accessibilityIdentifier("settings-full-library")
                }
                group("LIBRARY") {
                    row(PhotoAccessCopy.screenTitle, "photo.on.rectangle", .photoAccess, value: PhotoAccessCopy.status(model.photoAccess.access))
                        .accessibilityIdentifier("settings-photo-access")
                    row(IndexCopy.screenTitle, "magnifyingglass", .searchIndex, value: IndexCopy.value(model.index.status))
                        .accessibilityIdentifier("settings-search-index")
                    row(SavedPlacesCopy.screenTitle, "mappin.and.ellipse", .savedPlaces, value: SavedPlacesCopy.settingsValue(model.savedPlaces))
                        .accessibilityIdentifier("settings-saved-places")
                }
                group("APP") {
                    row("Appearance", "circle.lefthalf.filled", .appearance)
                    row("Revisit welcome", "arrow.counterclockwise", .onboarding)
                }
                group("ABOUT") {
                    row("Privacy", "hand.raised", .privacy)
                    row("Acknowledgements", "doc.text", .acknowledgements)
                }
                #if DEBUG
                group("DEVELOPER") {
                    LZToggleRow("Sample store prices", subtitle: "Fake store, nothing is charged. Restart Lahza to apply.",
                                systemImage: "hammer", isOn: $sampleStorePrices)
                        .accessibilityIdentifier("developer-sample-prices")
                    row("Locked results row", "lock", .lockedResults)
                        .accessibilityIdentifier("developer-locked-results")
                    row(LibraryCensusCopy.screenTitle, "chart.bar.doc.horizontal", .libraryCensus)
                        .accessibilityIdentifier("developer-library-census")
                    row("Index inspector", "tablecells", .indexInspector)
                        .accessibilityIdentifier("developer-index-inspector")
                    row("Label lab", "tag", .labelLab)
                        .accessibilityIdentifier("developer-label-lab")
                }
                #endif
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("\(Brand.name) · Version \(version)").lzText(.caption).foregroundStyle(.lz(.muted))
                }
            }
            .lzPage()
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(.lz(.bg))
        .tint(Color.lz(.accent))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-home")
        .task(id: model.index.version) { await model.savedPlaces.load() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).lzText(.label).foregroundStyle(.lz(.muted))
            LZRowGroup(content: content)
        }
    }

    private func row(_ title: String, _ symbol: String, _ route: Route, value: String? = nil) -> some View {
        ListRow(title, systemImage: symbol, value: value, accessory: .chevron) { model.open(route) }
    }
}

extension View {
    /// The shared look of the settings forms: paper background, accent tint, an inline title.
    func settingsForm(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(.lz(.bg))
            .tint(Color.lz(.accent))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
