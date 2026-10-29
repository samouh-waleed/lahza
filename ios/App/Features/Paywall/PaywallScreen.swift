import LZBilling
import LZCore
import LZDesign
import SwiftUI

/// The one-time full-library unlock (full screen): what stays free, what the unlock adds, the store's
/// price, Restore purchases and the legal links. One non-consumable, so never subscription or trial
/// wording (decision 32); the store logic underneath is ``PaywallModel``.
struct PaywallScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var paywall: PaywallModel?

    var body: some View {
        Group {
            if let paywall {
                PaywallContent(paywall: paywall)
            } else {
                AppLoadingView(label: BillingCopy.loadingPrice)
            }
        }
        .background(.lz(.bg))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(BillingCopy.closeLabel, systemImage: "xmark") { dismiss() }
                    .accessibilityIdentifier("paywall-close")
            }
        }
        .task {
            guard paywall == nil else { return }
            let created = model.makePaywallModel()
            paywall = created
            await created.load()
        }
        // A container, so the identifier doesn't replace the buttons' own (`paywall-purchase`, …).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall")
    }
}

private struct PaywallContent: View {
    let paywall: PaywallModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.xl) {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(BillingCopy.eyebrow).lzText(.label).foregroundStyle(.lz(.accent))
                    Text(BillingCopy.paywallTitle)
                        .lzText(.displayLarge)
                        .foregroundStyle(.lz(.ink))
                        .accessibilityAddTraits(.isHeader)
                    Text(BillingCopy.paywallSubtitle).lzText(.body).foregroundStyle(.lz(.muted))
                }
                VStack(spacing: LZSpace.md) {
                    FeatureCard(title: BillingCopy.unlockTitle, features: BillingCopy.unlockFeatures, highlighted: true) { price }
                    FeatureCard(title: BillingCopy.freeTitle, features: BillingCopy.freeFeatures, highlighted: false) { EmptyView() }
                }
                if case .unavailable(let message) = paywall.phase {
                    Notice(.warn, message: message, actionTitle: BillingCopy.tryAgain) { Task { await paywall.load() } }
                }
                if paywall.usesTestStore { Notice(.info, message: BillingCopy.testStoreNotice) }
            }
            .lzPage()
            .padding(.vertical, LZSpace.lg)
        }
        .safeAreaInset(edge: .bottom) { actions }
        .onChange(of: paywall.notice) { _, notice in handle(notice) }
    }

    /// The store's price, verbatim, beside the unlock's title.
    @ViewBuilder private var price: some View {
        if let offer = paywall.offer {
            VStack(alignment: .trailing, spacing: 0) {
                Text(offer.priceString).lzText(.title).foregroundStyle(.lz(.ink))
                Text(BillingCopy.priceCaption).lzText(.caption).foregroundStyle(.lz(.muted))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("paywall-price")
        } else if paywall.phase == .loading {
            LZLoader(.star, size: 20, label: BillingCopy.loadingPrice)
        }
    }

    private var actions: some View {
        VStack(spacing: LZSpace.sm) {
            if paywall.isUnlocked {
                Notice(.success, message: BillingCopy.unlockedNotice)
            } else {
                LZButton(paywall.purchaseTitle, isLoading: paywall.phase == .purchasing, fullWidth: true) {
                    Task { await paywall.purchase() }
                }
                .disabled(!paywall.canPurchase)
                .accessibilityIdentifier("paywall-purchase")
                Text(BillingCopy.purchaseFootnote)
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
                    .multilineTextAlignment(.center)
            }
            ViewThatFits {
                HStack(spacing: LZSpace.lg) { links }
                VStack(spacing: LZSpace.sm) { links }
            }
            .font(.footnote)
            .tint(Color.lz(.accent))
        }
        .padding(.horizontal, LZLayout.gutter)
        .padding(.top, LZSpace.md)
        .padding(.bottom, LZSpace.sm)
        .background(.lz(.bg))
    }

    @ViewBuilder private var links: some View {
        Button(paywall.phase == .restoring ? BillingCopy.restoring : BillingCopy.restorePurchases) {
            Task { await paywall.restore() }
        }
        .disabled(paywall.isBusy)
        .accessibilityIdentifier("paywall-restore")
        Link(BillingCopy.termsOfUse, destination: paywall.termsURL)
        Link(BillingCopy.privacyPolicy, destination: paywall.privacyURL)
    }

    private func handle(_ notice: PaywallModel.Notice?) {
        guard let notice else { return }
        model.toasts.show(notice.message)
        paywall.clearNotice()
        if notice == .purchased || notice == .restored { dismiss() }
    }
}

/// What one side of the comparison includes: the unlock (raised, accent icons, the price) or what
/// stays free (recessed).
private struct FeatureCard<Trailing: View>: View {
    let title: String
    let features: [(symbol: String, text: String)]
    let highlighted: Bool
    @ViewBuilder let trailing: () -> Trailing
    /// One icon column, so every line's text starts at the same edge.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

    var body: some View {
        PaperCard(style: highlighted ? .raised : .recessed) {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                LZAdaptiveStack(spacing: LZSpace.sm, verticalAlignment: .firstTextBaseline) {
                    Text(title)
                        .lzText(highlighted ? .title : .headline)
                        .foregroundStyle(.lz(.ink))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    trailing()
                }
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    ForEach(features, id: \.text) { feature in
                        Label {
                            Text(feature.text).lzText(.subheadline).foregroundStyle(.lz(.ink))
                        } icon: {
                            Image(systemName: feature.symbol)
                                .foregroundStyle(.lz(highlighted ? .accent : .muted))
                                .frame(width: iconWidth)
                        }
                    }
                }
            }
        }
    }
}
