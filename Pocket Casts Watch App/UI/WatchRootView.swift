import Combine
import PocketCastsServer
import SwiftUI

/// Root of the watch app. When signed into a PodHopper account it shows the play-source picker; when
/// signed out it shows an onboarding prompt that leads into pairing, so a fresh watch is never a dead
/// end. Reacts live to sign-in and sign-out.
struct WatchRootView: View {
    @StateObject private var model = WatchRootModel()

    var body: some View {
        if model.isLoggedIn {
            SourceInterfaceNavigationView()
        } else {
            WatchOnboardingView()
        }
    }
}

final class WatchRootModel: ObservableObject {
    @Published var isLoggedIn: Bool

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
}

struct WatchOnboardingView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    Text("PodHopper")
                        .font(.headline)
                    Text("Sign in to sync your podcasts to this watch and listen without your phone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.gray)
                    NavigationLink(destination: WatchPairingView()) {
                        Text("Sign in")
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Welcome")
        }
    }
}
