import SwiftUI

/// PodHopper's sign-in / sign-up / password-recovery / account screens. Mirrors the Android
/// PodHopperOnboarding login and signup screens: same copy, same field layout, same actions. Themed
/// with the app's colors so it matches the active theme.
struct PodHopperAuthRootView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperAuthViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            AppTheme.color(for: .primaryUi01, theme: theme).ignoresSafeArea()

            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, 72)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }

            Button {
                viewModel.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryIcon02, theme: theme))
                    .padding(16)
            }
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.mode {
        case .login:
            PodHopperLoginForm(viewModel: viewModel)
        case .signup:
            PodHopperSignupForm(viewModel: viewModel)
        case .recover:
            PodHopperRecoverForm(viewModel: viewModel)
        case .account:
            PodHopperAccountForm(viewModel: viewModel)
        }
    }
}

// MARK: - Login

private struct PodHopperLoginForm: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperAuthViewModel

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            PodHopperAuthHeader(
                title: "Log in",
                subtitle: "Sign in with your PodHopper account. Use the same account on every device to keep them in sync."
            )

            VStack(spacing: 12) {
                PodHopperAuthField(systemIcon: "envelope", placeholder: "Email Address", text: $email, isEmail: true)
                PodHopperAuthField(systemIcon: "key", placeholder: "Password", text: $password, isSecure: true)
            }

            PodHopperStatusText(status: viewModel.status)

            PodHopperPrimaryButton(title: "Log in", busy: viewModel.status == .busy) {
                viewModel.signIn(email: email, password: password)
            }

            VStack(spacing: 18) {
                PodHopperLinkButton(title: "Create account") {
                    viewModel.resetStatus()
                    viewModel.mode = .signup
                }
                PodHopperLinkButton(title: "Forgot password?") {
                    viewModel.resetStatus()
                    viewModel.mode = .recover
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Signup

private struct PodHopperSignupForm: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperAuthViewModel

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            PodHopperAuthHeader(
                title: "Create account",
                subtitle: "Create a PodHopper account. Use the same account on every device to keep them in sync."
            )

            if viewModel.status == .confirmEmail {
                PodHopperInfoPanel(
                    title: "Check your email",
                    message: "We sent a confirmation link to finish setting up your account. Open it, then come back and log in."
                )
                PodHopperPrimaryButton(title: "Back to login", busy: false) {
                    viewModel.resetStatus()
                    viewModel.mode = .login
                }
            } else {
                VStack(spacing: 12) {
                    PodHopperAuthField(systemIcon: "envelope", placeholder: "Email Address", text: $email, isEmail: true)
                    PodHopperAuthField(systemIcon: "key", placeholder: "Password", text: $password, isSecure: true)
                }

                PodHopperStatusText(status: viewModel.status)

                PodHopperPrimaryButton(title: "Create account", busy: viewModel.status == .busy) {
                    viewModel.signUp(email: email, password: password)
                }

                PodHopperLinkButton(title: "Back to login") {
                    viewModel.resetStatus()
                    viewModel.mode = .login
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Recover

private struct PodHopperRecoverForm: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperAuthViewModel

    @State private var email = ""

    var body: some View {
        VStack(spacing: 24) {
            PodHopperAuthHeader(
                title: "Reset password",
                subtitle: "Enter your account email and we'll send you a link to reset your password."
            )

            if viewModel.status == .recoverSent {
                PodHopperInfoPanel(
                    title: "Check your email",
                    message: "If an account exists for that address, a password reset link is on its way."
                )
                PodHopperPrimaryButton(title: "Back to login", busy: false) {
                    viewModel.resetStatus()
                    viewModel.mode = .login
                }
            } else {
                PodHopperAuthField(systemIcon: "envelope", placeholder: "Email Address", text: $email, isEmail: true)

                PodHopperStatusText(status: viewModel.status)

                PodHopperPrimaryButton(title: "Send reset email", busy: viewModel.status == .busy) {
                    viewModel.recoverPassword(email: email)
                }

                PodHopperLinkButton(title: "Back to login") {
                    viewModel.resetStatus()
                    viewModel.mode = .login
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Account (signed in)

private struct PodHopperAccountForm: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperAuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Logged in as")
                .font(.system(size: 18))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .padding(.top, 24)

            Text(viewModel.signedInEmail)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .multilineTextAlignment(.center)

            PodHopperPrimaryButton(title: "Logout", busy: false) {
                viewModel.logout()
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Shared components

private struct PodHopperAuthHeader: View {
    @EnvironmentObject var theme: Theme
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            Text(subtitle)
                .font(.system(size: 17))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PodHopperAuthField: View {
    @EnvironmentObject var theme: Theme
    let systemIcon: String
    let placeholder: String
    @Binding var text: String
    var isEmail: Bool = false
    var isSecure: Bool = false

    @FocusState private var focused: Bool
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemIcon)
                .font(.system(size: 18))
                .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                .frame(width: 24)

            Group {
                if isSecure && !reveal {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: 18))
            .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(isEmail ? .emailAddress : .default)

            if isSecure {
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 18))
                        .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    focused ? AppTheme.color(for: .primaryInteractive01, theme: theme)
                            : AppTheme.color(for: .primaryUi05, theme: theme),
                    lineWidth: focused ? 2 : 1
                )
        )
    }
}

private struct PodHopperPrimaryButton: View {
    @EnvironmentObject var theme: Theme
    let title: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.color(for: .primaryInteractive02, theme: theme)))
                }
            }
        }
        .buttonStyle(RoundedButtonStyle(theme: theme))
        .disabled(busy)
    }
}

private struct PodHopperLinkButton: View {
    @EnvironmentObject var theme: Theme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
        }
    }
}

private struct PodHopperStatusText: View {
    let status: PodHopperAuthViewModel.Status

    var body: some View {
        if case .error(let message) = status {
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(Color(red: 0.86, green: 0.31, blue: 0.31))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PodHopperInfoPanel: View {
    @EnvironmentObject var theme: Theme
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            Text(message)
                .font(.system(size: 16))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
