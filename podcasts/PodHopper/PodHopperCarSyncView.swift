import Combine
import PocketCastsServer
import SwiftUI

/// PodHopper's "Sync Account to Car App" screen. Mirrors the Android PodHopperCarSyncFragment: the
/// signed-in user types the pairing code shown on their car (or watch) and this approves it against
/// their PodHopper account through the Supabase pairing edge function. One screen serves any device
/// that shows a code.
struct PodHopperCarSyncView: View {
    @EnvironmentObject var theme: Theme
    @StateObject private var viewModel = PodHopperCarSyncViewModel()
    @State private var code = ""

    private let loggedOutText = "This option requires you to be logged into a PodHopper account. Tap on the Profile page and login or create your account first."
    private let instructions = "Open PodHopper on your car and it will show a pairing code. Enter that code below to sign your car into your PodHopper account."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.isLoggedIn {
                    Text(instructions)
                        .font(.system(size: 16))
                        .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                    TextField("Pairing code", text: Binding(
                        get: { code },
                        set: { code = $0.uppercased() }
                    ))
                    .font(.system(size: 18))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.color(for: .primaryUi05, theme: theme), lineWidth: 1)
                    )
                    .padding(.top, 20)

                    Button {
                        viewModel.pair(rawCode: code)
                    } label: {
                        ZStack {
                            Text("Pair Car")
                                .opacity(viewModel.pairingState == .submitting ? 0 : 1)
                            if viewModel.pairingState == .submitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.color(for: .primaryInteractive02, theme: theme)))
                            }
                        }
                    }
                    .buttonStyle(RoundedButtonStyle(theme: theme))
                    .disabled(viewModel.pairingState == .submitting)
                    .padding(.top, 20)

                    if let status = statusText {
                        Text(status)
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                            .padding(.top, 12)
                    }
                } else {
                    Text(loggedOutText)
                        .font(.system(size: 16))
                        .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(AppTheme.color(for: .primaryUi02, theme: theme).ignoresSafeArea())
    }

    private var statusText: String? {
        switch viewModel.pairingState {
        case .submitting:
            return "Pairing your car..."
        case .success:
            return "Your car has been paired successfully."
        case .error:
            return "Pairing failed. Check the code on your car and try again."
        case .idle:
            return nil
        }
    }
}

final class PodHopperCarSyncViewModel: ObservableObject {
    enum PairingState {
        case idle
        case submitting
        case success
        case error
    }

    @Published var isLoggedIn: Bool
    @Published var pairingState: PairingState = .idle

    private var cancellables = Set<AnyCancellable>()

    init() {
        isLoggedIn = PodHopperSupabaseClient.shared.isLoggedIn()
        PodHopperSupabaseClient.shared.loginState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loggedIn in
                self?.isLoggedIn = loggedIn
            }
            .store(in: &cancellables)
    }

    func pair(rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.isEmpty {
            pairingState = .error
            return
        }
        pairingState = .submitting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success: Bool
            do {
                try PodHopperSupabaseClient.shared.approveCarPairing(code: code)
                success = true
            } catch {
                success = false
            }
            DispatchQueue.main.async {
                self?.pairingState = success ? .success : .error
            }
        }
    }
}
