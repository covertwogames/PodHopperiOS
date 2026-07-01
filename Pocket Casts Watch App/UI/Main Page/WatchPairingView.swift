import Combine
import PocketCastsServer
import SwiftUI
import WatchKit

/// Signs this watch into a PodHopper account using the device-pairing code flow. The watch asks the
/// pairing edge function for a code, the user types that code into the PodHopper phone app (Settings,
/// Sync Account to Car App), and once the phone approves it the watch claims a Supabase session and
/// turns on sync. This is the device side of the same pairing path the car uses; the one phone screen
/// approves either device.
struct WatchPairingView: View {
    @StateObject private var model = WatchPairingModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch model.state {
                case .loading:
                    ProgressView()
                    Text("Getting a code...")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                case .showingCode(let code):
                    Text("In the PodHopper app on your phone, open Settings then Sync Account to Car App, and enter this code:")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Text(code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .padding(.vertical, 8)
                    Text("Waiting for approval...")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("Signed in. Your podcasts will sync to this watch.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        model.start()
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Sign in")
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}

final class WatchPairingModel: ObservableObject {
    enum State {
        case loading
        case showingCode(String)
        case success
        case failed(String)
    }

    @Published var state: State = .loading

    private var pollTimer: Timer?
    private var currentCode: String?

    func start() {
        state = .loading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let code = try PodHopperSupabaseClient.shared.startPairing(deviceName: WKInterfaceDevice.current().name)
                DispatchQueue.main.async {
                    self.currentCode = code
                    self.state = .showingCode(code)
                    self.startPolling()
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed("Could not start sign in. Check your connection and try again.")
                }
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stop()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let code = currentCode else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if let tokenHash = try PodHopperSupabaseClient.shared.pollPairing(code: code) {
                    try PodHopperSupabaseClient.shared.claimPairingSession(tokenHash: tokenHash)
                    self.onSignedIn()
                    DispatchQueue.main.async {
                        self.stop()
                        self.state = .success
                    }
                }
                // A nil result means the code is still pending approval, so keep polling.
            } catch {
                DispatchQueue.main.async {
                    self.stop()
                    self.state = .failed("The code expired. Tap Try again for a new one.")
                }
            }
        }
    }

    /// Once signed in, pull the subscribed library from Supabase, keep it in sync, and refresh feeds
    /// on-device so episodes populate for standalone playback on the watch.
    private func onSignedIn() {
        PodHopperSubscriptionSync.shared.pullSubscriptions()
        PodHopperSubscriptionSync.shared.startPeriodicSync()
        RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: true)
    }
}
