import LZBilling
import LZDesign
import SwiftUI

/// Settings › Full library: whether the one-time unlock is active, the way to it, and Restore purchases.
struct FullLibrarySettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var paywall: PaywallModel?
    @State private var message: String?

    var body: some View {
        let isUnlocked = model.entitlement.isUnlocked
        Form {
            Section {
                VStack(alignment: .leading, spacing: LZSpace.xxs) {
                    Label(isUnlocked ? BillingCopy.unlockedStatus : BillingCopy.freeStatus,
                          systemImage: isUnlocked ? "checkmark.seal.fill" : "calendar")
                        .font(.headline)
                    Text(isUnlocked ? BillingCopy.unlockedDetail : BillingCopy.freeDetail).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                if !isUnlocked {
                    Button(BillingCopy.seeUnlock) { model.open(.paywall) }
                        .accessibilityIdentifier("full-library-unlock")
                }
                Button(paywall?.phase == .restoring ? BillingCopy.restoring : BillingCopy.restorePurchases) { restore() }
                    .disabled(paywall?.phase == .restoring)
                    .accessibilityIdentifier("full-library-restore")
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .settingsForm(BillingCopy.productName)
        .onAppear { if paywall == nil { paywall = model.makePaywallModel() } }
        .accessibilityIdentifier("full-library-settings")
    }

    private func restore() {
        guard let paywall else { return }
        Task {
            await paywall.restore()
            message = paywall.notice?.message
            paywall.clearNotice()
        }
    }
}
