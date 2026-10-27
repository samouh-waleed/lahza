import DDBilling
import DDDesign
import SwiftUI

/// Settings › Lahza Plus: the current plan, plans, restore and management.
struct SubscriptionSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var paywall: PaywallModel?
    @State private var message: String?

    var body: some View {
        let entitlement = model.entitlement
        Form {
            Section {
                if entitlement.isUnlocked {
                    Label(BillingCopy.plusIsActive, systemImage: "checkmark.seal.fill").font(.headline)
                    if entitlement.isInTrial { Text("You’re in your free trial.").foregroundStyle(.secondary) }
                    if !entitlement.willRenew { Text("Your plan won’t renew.").foregroundStyle(.secondary) }
                } else {
                    Label(BillingCopy.freePlan, systemImage: "calendar").font(.headline)
                    Text(BillingCopy.paywallSubtitle).foregroundStyle(.secondary)
                }
            }
            Section {
                if !entitlement.isUnlocked {
                    Button("See plans") { model.open(.paywall) }
                        .accessibilityIdentifier("subscription-plans")
                }
                Button(paywall?.phase == .restoring ? BillingCopy.restoring : BillingCopy.restorePurchases) { restore() }
                    .disabled(paywall?.phase == .restoring)
                    .accessibilityIdentifier("subscription-restore")
                if entitlement.isUnlocked {
                    Button(BillingCopy.manageSubscription) { manage() }
                        .accessibilityIdentifier("subscription-manage")
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .settingsForm(BillingCopy.plusName)
        .onAppear { if paywall == nil { paywall = model.makePaywallModel() } }
        .accessibilityIdentifier("subscription-settings")
    }

    private func restore() {
        guard let paywall else { return }
        Task {
            await paywall.restore()
            message = paywall.notice?.message
            paywall.clearNotice()
        }
    }

    private func manage() {
        guard let paywall else { return }
        Task {
            if !(await paywall.manageSubscription()) { message = BillingCopy.manageFallback }
        }
    }
}
