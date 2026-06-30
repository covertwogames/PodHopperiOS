import SwiftUI

/// PodHopper's Help & Feedback screen, opened from the Profile tab. Mirrors the Android
/// HelpFeedbackFragment: the PodHopper lockup, a thank-you line, a link to the website, and a link
/// to the feedback email. Themed with the app's colors so it matches the active theme.
struct PodHopperHelpView: View {
    @EnvironmentObject var theme: Theme
    @Environment(\.openURL) private var openURL

    private enum Constants {
        static let websiteURL = "https://podhopper.app"
        static let feedbackEmail = "feedback@covertwogames.com"
        static let lockupAspectRatio = 900.0 / 590.0
    }

    var body: some View {
        ZStack {
            AppTheme.color(for: .primaryUi01, theme: theme).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Image("podhopper-lockup")
                        .resizable()
                        .aspectRatio(Constants.lockupAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 60)
                        .padding(.top, 56)

                    Text("Thanks for using PodHopper!")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                    VStack(spacing: 4) {
                        Text("For additional information about the app, check out our website at:")
                            .multilineTextAlignment(.center)
                            .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                        Button {
                            open(Constants.websiteURL)
                        } label: {
                            Text("podhopper.app")
                                .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                        }
                    }

                    VStack(spacing: 4) {
                        Text("If you have any questions or feedback about the app, please share it with us at:")
                            .multilineTextAlignment(.center)
                            .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                        Button {
                            open("mailto:\(Constants.feedbackEmail)")
                        } label: {
                            Text(verbatim: Constants.feedbackEmail)
                                .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                        }
                    }

                    Spacer(minLength: 56)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else {
            return
        }
        openURL(url)
    }
}
