import SwiftUI

/// PodHopper: the one-time Terms of Service screen for people who were already using the app before
/// the Terms existed, so they never passed the create account box or the first-run notices. Mirrors
/// the Android PodHopperTermsActivity: the same wording and the same single way forward.
///
/// The main screen shows this whenever first-run setup is not being shown but the current Terms have
/// not been agreed to on this device. "Agree and continue" records the agreement on the device and,
/// when signed in, on the account. There is no close button and it cannot be swiped away, so the app
/// cannot be used without agreeing; opening the app again shows it again. Nothing is deleted or
/// signed out by leaving.
struct PodHopperTermsPromptView: View {
    @EnvironmentObject var theme: Theme
    @Environment(\.openURL) private var openURL

    /// Called when the person taps Agree and continue. The hosting controller records it and closes.
    let onAgree: () -> Void

    var body: some View {
        ZStack {
            AppTheme.color(for: .primaryUi01, theme: theme).ignoresSafeArea()

            // Centered when it fits, scrolling when it does not (small screens, large text).
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)
                        content
                            .frame(maxWidth: 520)
                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image("podhopper-lockup")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240)
                .frame(height: 160)

            Text(PodHopperTermsCopy.promptTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)

            Text(PodHopperTermsCopy.promptMessage)
                .font(.system(size: 17))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Button {
                openURL(PodHopperTerms.termsURL)
            } label: {
                Text(PodHopperTermsCopy.promptReadTerms)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .padding(.vertical, 10)
            }
            .padding(.top, 14)

            Button {
                openURL(PodHopperTerms.privacyURL)
            } label: {
                Text(PodHopperTermsCopy.promptReadPrivacy)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .padding(.vertical, 10)
            }

            Button(action: onAgree) {
                Text(PodHopperTermsCopy.promptAgree)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RoundedButtonStyle(theme: theme))
            .padding(.top, 20)

            PodHopperTermsLinksText(PodHopperTermsCopy.promptFooter)
                .padding(.top, 12)
        }
    }
}

/// Presents the one-time Terms screen full screen. Records the agreement and closes itself when the
/// person taps Agree and continue.
class PodHopperTermsPromptHostingController: ThemedHostingController<PodHopperTermsPromptView> {
    /// Called once the screen has closed after Agree and continue.
    var onFinished: (() -> Void)?

    init() {
        let finisher = PodHopperTermsPromptFinisher()
        super.init(rootView: PodHopperTermsPromptView(onAgree: {
            finisher.onAgree?()
        }))

        finisher.onAgree = { [weak self] in
            PodHopperTerms.shared.recordAgreement(method: .prompt)
            PodHopperTerms.shared.syncToAccountAsync()
            self?.dismiss(animated: true) { [weak self] in
                self?.onFinished?()
            }
        }
    }

    @MainActor dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Bridges the SwiftUI screen's Agree tap to the hosting controller. The controller is created after
/// its root view, so the root view captures this holder and the controller fills in the handler once
/// it exists.
private final class PodHopperTermsPromptFinisher {
    var onAgree: (() -> Void)?
}
