import DDBilling
import DDCore
import DDDesign
import SwiftUI

/// Lahza Plus plans (full screen). Placeholder copy and layout until the paywall is designed
/// (template-migration D9); the store logic underneath is real.
struct PaywallScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var paywall: PaywallModel?

    var body: some View {
        Group {
            if let paywall {
                PaywallContent(paywall: paywall)
            } else {
                AppLoadingView(label: BillingCopy.loadingPrices)
            }
        }
        .background(.dd(.bg))
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
        .accessibilityIdentifier("paywall")
    }
}

private struct PaywallContent: View {
    @Bindable var paywall: PaywallModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DDSpace.xl) {
                VStack(alignment: .leading, spacing: DDSpace.sm) {
                    Text(BillingCopy.plusName.uppercased()).ddText(.label).foregroundStyle(.dd(.accent))
                    Text(BillingCopy.paywallTitle).ddText(.displayLarge).foregroundStyle(.dd(.ink))
                    Text(BillingCopy.paywallSubtitle).ddText(.body).foregroundStyle(.dd(.muted))
                }
                VStack(alignment: .leading, spacing: DDSpace.lg) {
                    ForEach(BillingCopy.benefits, id: \.title) { benefit in
                        HStack(alignment: .top, spacing: DDSpace.md) {
                            IconBadge(benefit.symbol, tone: .accent)
                            VStack(alignment: .leading, spacing: DDSpace.xxs) {
                                Text(benefit.title).ddText(.headline).foregroundStyle(.dd(.ink))
                                Text(benefit.detail).ddText(.subheadline).foregroundStyle(.dd(.muted))
                            }
                        }
                    }
                }
                plans
                if let timeline = paywall.trialTimeline { TrialTimelineCard(timeline: timeline) }
                if paywall.usesTestStore { Notice(.info, message: BillingCopy.testStoreNotice) }
            }
            .ddPage()
            .padding(.vertical, DDSpace.lg)
        }
        .safeAreaInset(edge: .bottom) { actions }
        .onChange(of: paywall.notice) { _, notice in handle(notice) }
    }

    @ViewBuilder private var plans: some View {
        switch paywall.phase {
        case .idle, .loading:
            HStack(spacing: DDSpace.sm) {
                DDLoader(.star, size: 20, label: BillingCopy.loadingPrices)
                Text(BillingCopy.loadingPrices).ddText(.subheadline).foregroundStyle(.dd(.muted))
            }
        case .unavailable(let message):
            Notice(.warn, message: message, actionTitle: BillingCopy.tryAgain) { Task { await paywall.load() } }
        case .ready, .purchasing, .restoring:
            VStack(spacing: DDSpace.sm) {
                ForEach(paywall.catalog.offers, id: \.period) { offer in
                    PlanCard(offer: offer, isSelected: paywall.selectedPeriod == offer.period) { paywall.select(offer.period) }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DDSpace.sm) {
            DDButton(paywall.purchaseTitle, isLoading: paywall.phase == .purchasing, fullWidth: true) {
                Task { await paywall.purchase() }
            }
            .disabled(paywall.selectedOffer == nil || paywall.isBusy || paywall.phase == .loading)
            .accessibilityIdentifier("paywall-purchase")
            Text(BillingCopy.renewalDisclosure)
                .ddText(.caption)
                .foregroundStyle(.dd(.muted))
                .multilineTextAlignment(.center)
            HStack(spacing: DDSpace.lg) {
                Button(paywall.phase == .restoring ? BillingCopy.restoring : BillingCopy.restorePurchases) {
                    Task { await paywall.restore() }
                }
                .disabled(paywall.isBusy)
                Link(BillingCopy.termsOfUse, destination: paywall.termsURL)
                Link(BillingCopy.privacyPolicy, destination: paywall.privacyURL)
            }
            .font(.footnote)
            .tint(Color.dd(.accent))
        }
        .padding(.horizontal, DDLayout.gutter)
        .padding(.top, DDSpace.md)
        .padding(.bottom, DDSpace.sm)
        .background(.dd(.bg))
    }

    private func handle(_ notice: PaywallModel.Notice?) {
        guard let notice else { return }
        model.toasts.show(notice.message)
        paywall.clearNotice()
        if notice == .purchased || notice == .restored { dismiss() }
    }
}

/// One plan: period, billed price, per-month equivalent and a confirmed free trial.
private struct PlanCard: View {
    let offer: PlusOffer
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        PaperCard(style: isSelected ? .raised : .paper, action: select) {
            HStack(alignment: .center, spacing: DDSpace.md) {
                VStack(alignment: .leading, spacing: DDSpace.xxs) {
                    Text(offer.period.title).ddText(.headline).foregroundStyle(.dd(.ink))
                    Text(offer.billedPriceText).ddText(.subheadline).foregroundStyle(.dd(.muted))
                    if offer.period == .annual, let perMonth = offer.perMonthPrice {
                        Text("\(perMonth) / month").ddText(.caption).foregroundStyle(.dd(.muted))
                    }
                }
                Spacer()
                if let trial = offer.trial { Pill("\(trial.duration) free", tone: .sage) }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .dd(.accent) : .dd(.muted))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Today → 2 days before the trial ends → the first charge.
private struct TrialTimelineCard: View {
    let timeline: TrialTimeline

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: DDSpace.md) {
                Text(timeline.summary).ddText(.headline).foregroundStyle(.dd(.ink))
                ForEach(Array(timeline.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: DDSpace.md) {
                        Image(systemName: symbol(step.kind)).foregroundStyle(.dd(.accent)).frame(width: 22)
                        VStack(alignment: .leading, spacing: DDSpace.xxs) {
                            Text(step.title).ddText(.subheadline).foregroundStyle(.dd(.ink))
                            Text(step.detail).ddText(.caption).foregroundStyle(.dd(.muted))
                        }
                    }
                }
            }
        }
    }

    private func symbol(_ kind: TrialTimeline.Step.Kind) -> String {
        switch kind {
        case .start: "lock.open"
        case .billing: "creditcard"
        }
    }
}
