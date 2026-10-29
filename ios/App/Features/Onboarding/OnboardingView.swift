import LZCore
import LZDesign
import LZLibrary
import SwiftUI

/// First-run onboarding: what Lahza does, the privacy promise, then photo access. The photos step is
/// the pre-permission screen (App Review 5.1.1, decision 30): it explains why, and its only action,
/// Continue, shows the iOS prompt straight away. Any answer finishes onboarding; Lahza never blocks
/// on it.
struct OnboardingView: View {
    /// Opened again from Settings (shown as a cover, with a close button).
    var revisit = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    /// The last Continue was tapped (a second tap must not finish while the prompt is up).
    @State private var finishing = false

    enum Step: Int, CaseIterable {
        case welcome
        case privacy
        /// Photo access: Continue goes straight to the iOS prompt (no skip, no "not now").
        case photos
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(Color.lz(.accent))
                    .frame(maxWidth: 120)
                Spacer()
                if revisit {
                    LZIconButton("xmark", label: "Close", style: .glass, size: 40) { dismiss() }
                }
            }
            .padding(.horizontal, LZLayout.gutter)
            .padding(.top, LZSpace.md)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .privacy: PrivacyStep()
                    case .photos: PhotosStep()
                    }
                }
                .lzPage()
                .padding(.vertical, LZSpace.xl)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)

            LZButton(buttonTitle, isLoading: model.photoAccess.isRequesting, fullWidth: true) { advance() }
                .padding(.horizontal, LZLayout.gutter)
                .padding(.bottom, LZSpace.lg)
                .accessibilityIdentifier("onboarding-continue")
        }
        .background(.lz(.bg))
        .animation(.easeInOut(duration: 0.3), value: step)
        .accessibilityIdentifier("onboarding")
    }

    /// "Continue" throughout; "Done" when a revisit's photos step has nothing to ask.
    private var buttonTitle: String {
        step == .photos && revisit && !model.photoAccess.access.canAsk ? OnboardingCopy.done : OnboardingCopy.next
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
            return
        }
        guard !finishing else { return }
        finishing = true
        Task {
            if revisit {
                // Shows the prompt only if access is still undecided.
                await model.photoAccess.request()
                dismiss()
            } else {
                await model.finishOnboarding()
            }
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xl) {
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                Text(verbatim: Brand.name).lzText(.displayXL).foregroundStyle(.lz(.ink))
                Text(OnboardingCopy.welcome).lzText(.title).foregroundStyle(.lz(.ink))
                Text(OnboardingCopy.welcomeBody).lzText(.body).foregroundStyle(.lz(.muted))
            }
            VStack(alignment: .leading, spacing: LZSpace.lg) {
                ForEach(OnboardingCopy.promises, id: \.title) { promise in
                    HStack(alignment: .top, spacing: LZSpace.md) {
                        IconBadge(promise.symbol, tone: .accent)
                        VStack(alignment: .leading, spacing: LZSpace.xxs) {
                            Text(promise.title).lzText(.headline).foregroundStyle(.lz(.ink))
                            Text(promise.detail).lzText(.subheadline).foregroundStyle(.lz(.muted))
                        }
                    }
                }
            }
        }
    }
}

private struct PrivacyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xl) {
            IconBadge("lock.shield", tone: .sage, size: 56)
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                Text(OnboardingCopy.privacyTitle).lzText(.displaySmall).foregroundStyle(.lz(.ink))
                Text(OnboardingCopy.privacyBody).lzText(.body).foregroundStyle(.lz(.muted))
            }
            PaperCard {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    ForEach(OnboardingCopy.privacyPoints, id: \.self) { point in
                        Label(point, systemImage: "checkmark")
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.ink))
                    }
                }
            }
        }
    }
}

/// Why Lahza asks for photo access, before iOS does. Once access is decided (a revisit, or a
/// reinstall that kept it) it shows the current access instead of announcing the prompt.
private struct PhotosStep: View {
    @Environment(AppModel.self) private var model
    /// One width for every point's glyph, so the lines start together.
    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 24

    var body: some View {
        let store = model.photoAccess
        let access = store.access
        VStack(alignment: .leading, spacing: LZSpace.xl) {
            IconBadge("photo.on.rectangle.angled", tone: .accent, size: 56)
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                Text(OnboardingCopy.photosTitle).lzText(.displaySmall).foregroundStyle(.lz(.ink))
                Text(OnboardingCopy.photosBody)
                    .lzText(.body)
                    .foregroundStyle(.lz(.muted))
                Text(access.canAsk ? OnboardingCopy.photosNext : OnboardingCopy.photosBodyDecided)
                    .lzText(.body)
                    .foregroundStyle(.lz(.muted))
            }
            PaperCard {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    ForEach(points(for: access), id: \.text) { point in
                        Label {
                            Text(point.text)
                        } icon: {
                            Image(systemName: point.symbol).frame(width: glyphWidth)
                        }
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.ink))
                    }
                }
            }
            if !access.canAsk {
                Notice(access.canRead ? .success : .info, title: PhotoAccessCopy.headline(access),
                       message: PhotoAccessCopy.detail(access, count: store.readableCount))
                    .accessibilityIdentifier("onboarding-photo-status")
            }
        }
        .accessibilityIdentifier("onboarding-photos")
    }

    /// The Settings line is left out when access is restricted: then it can't be changed.
    private func points(for access: PhotoAccess) -> [(symbol: String, text: String)] {
        access == .restricted ? OnboardingCopy.photosPoints : OnboardingCopy.photosPoints + [OnboardingCopy.photosSettingsPoint]
    }
}

nonisolated enum OnboardingCopy {
    static let next = "Continue"
    static let done = "Done"
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
    ]
    static let photosTitle = "Lahza searches your photo library."
    static let photosBody = "Lahza reads the dates and places of your photos on this iPhone to find moments. Place names are looked up with Apple Maps; your photos never leave your device."
    static let photosNext = "Next, iOS asks for photo access. With full access Lahza can search every photo, or you can pick just some."
    static let photosBodyDecided = "With full access Lahza can search every photo; with limited access, only the ones you pick."
    static let photosPoints: [(symbol: String, text: String)] = [
        ("iphone", "Read only on this iPhone"),
        ("eye.slash", "Your Hidden album is never read"),
    ]
    static let photosSettingsPoint = (symbol: "gearshape", text: "Change it anytime in iPhone Settings")
}
