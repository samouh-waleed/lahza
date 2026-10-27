import DDBilling
import DDCore
import DDDesign
import SwiftUI

struct SettingsHomeScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make it yours.").ddText(.displayLarge)
                    Text("Your settings stay on this iPhone.").ddText(.body).foregroundStyle(.dd(.muted))
                }
                .padding(.bottom, 8)
                group("PLAN") {
                    row(BillingCopy.plusName, "sparkles", .subscription, value: model.entitlement.isUnlocked ? "Active" : "Free")
                }
                group("APP") {
                    row("Appearance", "circle.lefthalf.filled", .appearance)
                    row("Revisit welcome", "arrow.counterclockwise", .onboarding)
                }
                group("ABOUT") {
                    row("Privacy", "hand.raised", .privacy)
                    row("Acknowledgements", "doc.text", .acknowledgements)
                }
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("\(Brand.name) · Version \(version)").ddText(.caption).foregroundStyle(.dd(.muted))
                }
            }
            .ddPage()
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(.dd(.bg))
        .tint(Color.dd(.accent))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings-home")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).ddText(.label).foregroundStyle(.dd(.muted))
            DDRowGroup(content: content)
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
            .background(.dd(.bg))
            .tint(Color.dd(.accent))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
