import LZBilling
import LZCore
import LZDesign
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
        .accessibilityIdentifier("paywall")
    }
}

private struct PaywallContent: View {
    @Bindable var paywall: PaywallModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.xl) {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(BillingCopy.plusName.uppercased()).lzText(.label).foregroundStyle(.lz(.accent))
                    Text(BillingCopy.paywallTitle).lzText(.displayLarge).foregroundStyle(.lz(.ink))
                    Text(BillingCopy.paywallSubtitle).lzText(.body).foregroundStyle(.lz(.muted))
                }
                VStack(alignment: .leading, spacing: LZSpace.lg) {
                    ForEach(BillingCopy.benefits, id: \.title) { benefit in
                        HStack(alignment: .top, spacing: LZSpace.md) {
                            IconBadge(benefit.symbol, tone: .accent)
                            VStack(alignment: .leading, spacing: LZSpace.xxs) {
                                Text(benefit.title).lzText(.headline).foregroundStyle(.lz(.ink))
                                Text(benefit.detail).lzText(.subheadline).foregroundStyle(.lz(.muted))
                            }
                        }
                    }
                }
                plans
                if let timeline = paywall.trialTimeline { TrialTimelineCard(timeline: timeline) }
                if paywall.usesTestStore { Notice(.info, message: BillingCopy.testStoreNotice) }
            }
            .lzPage()
            .padding(.vertical, LZSpace.lg)
        }
        .safeAreaInset(edge: .bottom) { actions }
        .onChange(of: paywall.notice) { _, notice in handle(notice) }
    }

    @ViewBuilder private var plans: some View {
        switch paywall.phase {
        case .idle, .loading:
            HStack(spacing: LZSpace.sm) {
                LZLoader(.star, size: 20, label: BillingCopy.loadingPrices)
                Text(BillingCopy.loadingPrices).lzText(.subheadline).foregroundStyle(.lz(.muted))
            }
        case .unavailable(let message):
            Notice(.warn, message: message, actionTitle: BillingCopy.tryAgain) { Task { await paywall.load() } }
        case .ready, .purchasing, .restoring:
            VStack(spacing: LZSpace.sm) {
                ForEach(paywall.catalog.offers, id: \.period) { offer in
                    PlanCard(offer: offer, isSelected: paywall.selectedPeriod == offer.period) { paywall.select(offer.period) }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: LZSpace.sm) {
            LZButton(paywall.purchaseTitle, isLoading: paywall.phase == .purchasing, fullWidth: true) {
                Task { await paywall.purchase() }
            }
            .disabled(paywall.selectedOffer == nil || paywall.isBusy || paywall.phase == .loading)
            .accessibilityIdentifier("paywall-purchase")
            Text(BillingCopy.renewalDisclosure)
                .lzText(.caption)
                .foregroundStyle(.lz(.muted))
                .multilineTextAlignment(.center)
            HStack(spacing: LZSpace.lg) {
                Button(paywall.phase == .restoring ? BillingCopy.restoring : BillingCopy.restorePurchases) {
                    Task { await paywall.restore() }
                }
                .disabled(paywall.isBusy)
                Link(BillingCopy.termsOfUse, destination: paywall.termsURL)
                Link(BillingCopy.privacyPolicy, destination: paywall.privacyURL)
            }
            .font(.footnote)
            .tint(Color.lz(.accent))
        }
        .padding(.horizontal, LZLayout.gutter)
        .padding(.top, LZSpace.md)
        .padding(.bottom, LZSpace.sm)
        .background(.lz(.bg))
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
            HStack(alignment: .center, spacing: LZSpace.md) {
                VStack(alignment: .leading, spacing: LZSpace.xxs) {
                    Text(offer.period.title).lzText(.headline).foregroundStyle(.lz(.ink))
                    Text(offer.billedPriceText).lzText(.subheadline).foregroundStyle(.lz(.muted))
                    if offer.period == .annual, let perMonth = offer.perMonthPrice {
                        Text("\(perMonth) / month").lzText(.caption).foregroundStyle(.lz(.muted))
                    }
                }
                Spacer()
                if let trial = offer.trial { Pill("\(trial.duration) free", tone: .sage) }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .lz(.accent) : .lz(.muted))
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
            VStack(alignment: .leading, spacing: LZSpace.md) {
                Text(timeline.summary).lzText(.headline).foregroundStyle(.lz(.ink))
                ForEach(Array(timeline.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: LZSpace.md) {
                        Image(systemName: symbol(step.kind)).foregroundStyle(.lz(.accent)).frame(width: 22)
                        VStack(alignment: .leading, spacing: LZSpace.xxs) {
                            Text(step.title).lzText(.subheadline).foregroundStyle(.lz(.ink))
                            Text(step.detail).lzText(.caption).foregroundStyle(.lz(.muted))
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
