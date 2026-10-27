import DDCore
import DDDesign
import SwiftUI

/// First-run onboarding: what Lahza does, then the privacy promise. Photo access joins as the
/// last step once library indexing exists (template-migration E1).
struct OnboardingView: View {
    /// Opened again from Settings (shown as a cover, with a close button).
    var revisit = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome
        case privacy
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(Color.dd(.accent))
                    .frame(maxWidth: 120)
                Spacer()
                if revisit {
                    DDIconButton("xmark", label: "Close", style: .glass, size: 40) { dismiss() }
                }
            }
            .padding(.horizontal, DDLayout.gutter)
            .padding(.top, DDSpace.md)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .privacy: PrivacyStep()
                    }
                }
                .ddPage()
                .padding(.vertical, DDSpace.xl)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)

            DDButton(step == .privacy ? OnboardingCopy.start : OnboardingCopy.next, fullWidth: true) { advance() }
                .padding(.horizontal, DDLayout.gutter)
                .padding(.bottom, DDSpace.lg)
                .accessibilityIdentifier("onboarding-continue")
        }
        .background(.dd(.bg))
        .animation(.easeInOut(duration: 0.3), value: step)
        .accessibilityIdentifier("onboarding")
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else if revisit {
            dismiss()
        } else {
            model.completeOnboarding()
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DDSpace.xl) {
            VStack(alignment: .leading, spacing: DDSpace.sm) {
                Text(verbatim: Brand.name).ddText(.displayXL).foregroundStyle(.dd(.ink))
                Text(OnboardingCopy.welcome).ddText(.title).foregroundStyle(.dd(.ink))
                Text(OnboardingCopy.welcomeBody).ddText(.body).foregroundStyle(.dd(.muted))
            }
            VStack(alignment: .leading, spacing: DDSpace.lg) {
                ForEach(OnboardingCopy.promises, id: \.title) { promise in
                    HStack(alignment: .top, spacing: DDSpace.md) {
                        IconBadge(promise.symbol, tone: .accent)
                        VStack(alignment: .leading, spacing: DDSpace.xxs) {
                            Text(promise.title).ddText(.headline).foregroundStyle(.dd(.ink))
                            Text(promise.detail).ddText(.subheadline).foregroundStyle(.dd(.muted))
                        }
                    }
                }
            }
        }
    }
}

private struct PrivacyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DDSpace.xl) {
            IconBadge("lock.shield", tone: .sage, size: 56)
            VStack(alignment: .leading, spacing: DDSpace.sm) {
                Text(OnboardingCopy.privacyTitle).ddText(.displaySmall).foregroundStyle(.dd(.ink))
                Text(OnboardingCopy.privacyBody).ddText(.body).foregroundStyle(.dd(.muted))
            }
            PaperCard {
                VStack(alignment: .leading, spacing: DDSpace.sm) {
                    ForEach(OnboardingCopy.privacyPoints, id: \.self) { point in
                        Label(point, systemImage: "checkmark")
                            .ddText(.subheadline)
                            .foregroundStyle(.dd(.ink))
                    }
                }
            }
        }
    }
}

nonisolated enum OnboardingCopy {
    static let next = "Continue"
    static let start = "Get started"
    static let welcome = "Find any moment by describing it."
    static let welcomeBody = "Tell Lahza what you remember and it finds the photos, grouped as the moments they belong to."
    static let promises: [(symbol: String, title: String, detail: String)] = [
        ("text.magnifyingglass", "Describe, don't scroll", "“Soccer at the park last summer” is enough."),
        ("mappin.and.ellipse", "The right place", "Places come from where your photos were taken, not how they look."),
        ("checkmark.seal", "Every result explained", "See why each photo matched, and fix mistakes in a tap."),
    ]
    static let privacyTitle = "Your photos stay on your iPhone."
    static let privacyBody = "Lahza works with your library on this device. There's no account and no Lahza server."
    static let privacyPoints = [
        "Photos are never uploaded",
        "No account, no tracking, no ads",
        "Turn off photo access anytime in iPhone Settings",
    ]
}
