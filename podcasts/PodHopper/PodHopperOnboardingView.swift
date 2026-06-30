import SwiftUI

/// PodHopper's first-run onboarding. Mirrors the Android PodHopperOnboarding flow: a welcome screen
/// with a login or skip choice, the reused PodHopper auth screen for login and sign up, and a
/// notifications screen. This replaces the old Pocket Casts intro, interests, and recommendations
/// onboarding.
struct PodHopperOnboardingRootView: View {
    @EnvironmentObject var theme: Theme

    @StateObject private var authViewModel = PodHopperAuthViewModel()
    @State private var step: Step = .welcome
    @State private var showSkipWarning = false

    /// Called when the user finishes onboarding. The hosting controller dismisses on this.
    let onFinished: () -> Void

    enum Step {
        case welcome
        case auth
        case notifications
    }

    var body: some View {
        ZStack {
            AppTheme.color(for: .primaryUi01, theme: theme).ignoresSafeArea()

            content
        }
        .onAppear {
            authViewModel.mode = .login
            authViewModel.onAuthenticated = {
                withAnimation {
                    step = .notifications
                }
            }
            authViewModel.onClose = {
                authViewModel.resetStatus()
                authViewModel.mode = .login
                withAnimation {
                    step = .welcome
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            PodHopperWelcomeStep(
                onLogin: {
                    withAnimation {
                        step = .auth
                    }
                },
                onSkip: {
                    showSkipWarning = true
                }
            )
            .alert("Skip account setup?", isPresented: $showSkipWarning) {
                Button("Continue without account") {
                    withAnimation {
                        step = .notifications
                    }
                }
                Button("Back to login", role: .cancel) {}
            } message: {
                Text("You are welcome to use PodHopper without an account, however, syncing between devices will not work.")
            }
        case .auth:
            PodHopperAuthRootView(viewModel: authViewModel)
        case .notifications:
            PodHopperNotificationsStep { receiveNotifications in
                if receiveNotifications {
                    NotificationsHelper.shared.enablePush()
                    NotificationsHelper.shared.registerForPushNotifications { _ in }
                }
                onFinished()
            }
        }
    }
}

// MARK: - Welcome

private struct PodHopperWelcomeStep: View {
    @EnvironmentObject var theme: Theme
    let onLogin: () -> Void
    let onSkip: () -> Void

    var body: some View {
        PodHopperOnboardingScaffold {
            Image("podhopper-lockup")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240)
                .frame(height: 160)

            Text("Welcome to PodHopper!")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("For the best experience, please log in or create your account.")
                .font(.system(size: 17))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Button(action: onLogin) {
                Text("Log in / Sign up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RoundedButtonStyle(theme: theme))
            .padding(.top, 32)

            Button(action: onSkip) {
                Text("Skip")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Notifications

private struct PodHopperNotificationsStep: View {
    @EnvironmentObject var theme: Theme
    let onGetStarted: (Bool) -> Void

    @State private var receiveNotifications = true

    var body: some View {
        PodHopperOnboardingScaffold {
            Image("podhopper-lockup")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200)
                .frame(height: 130)

            Text("Stay up to date!")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("Notifications are the best way to keep track of new episodes.")
                .font(.system(size: 17))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Button {
                receiveNotifications.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: receiveNotifications ? "checkmark.square.fill" : "square")
                        .font(.system(size: 22))
                        .foregroundColor(AppTheme.color(for: receiveNotifications ? .primaryInteractive01 : .primaryIcon02, theme: theme))
                    Text("Receive Notifications")
                        .font(.system(size: 17))
                        .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                }
            }
            .padding(.top, 32)

            Button {
                onGetStarted(receiveNotifications)
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RoundedButtonStyle(theme: theme))
            .padding(.top, 24)
        }
    }
}

// MARK: - Scaffold

/// Centers a step's content vertically and lets it scroll when it is taller than the screen.
private struct PodHopperOnboardingScaffold<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    content()
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}
