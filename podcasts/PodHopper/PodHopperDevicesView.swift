import PocketCastsServer
import SwiftUI

/// PodHopper: Settings > Signed-in devices. Lists every place the account is signed in (phones,
/// tablets, cars, watches) and lets the person sign any other device out, or all of them at once.
/// This is how someone signs out of a car they have already handed back. Mirrors the Android
/// PodHopperDevicesFragment, with the same wording.
struct PodHopperDevicesView: View {
    @EnvironmentObject var theme: Theme
    @StateObject private var viewModel = PodHopperDevicesViewModel()

    /// The device waiting for a yes or no.
    @State private var confirmDevice: PodHopperDevices.Device?
    @State private var confirmOthers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.status {
                case .loggedOut:
                    message(PodHopperDevicesCopy.loggedOut)
                case .loading:
                    HStack(spacing: 12) {
                        ProgressView()
                        message(PodHopperDevicesCopy.loading)
                    }
                case .loadFailed:
                    message(PodHopperDevicesCopy.loadFailed)
                    Button(PodHopperDevicesCopy.retry) {
                        viewModel.load()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .padding(.top, 12)
                case .ready:
                    deviceList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(AppTheme.color(for: .primaryUi02, theme: theme).ignoresSafeArea())
        .onAppear {
            viewModel.load()
        }
        .alert(PodHopperDevicesCopy.signOut, isPresented: Binding(
            get: { confirmDevice != nil },
            set: { if !$0 { confirmDevice = nil } }
        )) {
            Button(PodHopperDevicesCopy.signOut, role: .destructive) {
                if let device = confirmDevice {
                    viewModel.signOut(device)
                }
                confirmDevice = nil
            }
            Button(PodHopperDevicesCopy.cancel, role: .cancel) {
                confirmDevice = nil
            }
        } message: {
            Text(PodHopperDevicesCopy.confirmOne)
        }
        .alert(PodHopperDevicesCopy.signOutOthers, isPresented: $confirmOthers) {
            Button(PodHopperDevicesCopy.signOutOthers, role: .destructive) {
                viewModel.signOutOthers()
            }
            Button(PodHopperDevicesCopy.cancel, role: .cancel) {}
        } message: {
            Text(PodHopperDevicesCopy.confirmOthers)
        }
    }

    @ViewBuilder private var deviceList: some View {
        message(PodHopperDevicesCopy.intro)

        if let notice = viewModel.noticeText {
            Text(notice)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }

        VStack(spacing: 0) {
            ForEach(viewModel.devices) { device in
                PodHopperDeviceRow(device: device, working: viewModel.isWorking) {
                    confirmDevice = device
                }
                if device.id != viewModel.devices.last?.id {
                    Rectangle()
                        .fill(AppTheme.color(for: .primaryUi05, theme: theme))
                        .frame(height: 1)
                }
            }
        }
        .padding(.top, 16)

        if viewModel.devices.contains(where: { !$0.isThisDevice }) {
            Button {
                confirmOthers = true
            } label: {
                Text(PodHopperDevicesCopy.signOutOthers)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RoundedButtonStyle(theme: theme))
            .disabled(viewModel.isWorking)
            .padding(.top, 20)
        }

        Text(PodHopperDevicesCopy.footer)
            .font(.system(size: 14))
            .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One device: what it is, when it was last active (or "This device"), and Sign out for the others.
private struct PodHopperDeviceRow: View {
    @EnvironmentObject var theme: Theme
    let device: PodHopperDevices.Device
    let working: Bool
    let onSignOut: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PodHopperDevicesCopy.name(for: device))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = PodHopperDevicesCopy.detail(for: device) {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !device.isThisDevice {
                Button(action: onSignOut) {
                    Text(PodHopperDevicesCopy.signOut)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                }
                .disabled(working)
            }
        }
        .padding(.vertical, 12)
    }
}

/// Drives the Signed-in devices screen. All network work runs off the main thread.
final class PodHopperDevicesViewModel: ObservableObject {
    enum Status {
        case loading
        case loggedOut
        case loadFailed
        case ready
    }

    enum Notice {
        case none
        case working
        case doneOne
        case doneOthers
        case failed
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var devices: [PodHopperDevices.Device] = []
    @Published private(set) var notice: Notice = .none

    var isWorking: Bool { notice == .working }

    var noticeText: String? {
        switch notice {
        case .none:
            return nil
        case .working:
            return PodHopperDevicesCopy.working
        case .doneOne:
            return PodHopperDevicesCopy.doneOne
        case .doneOthers:
            return PodHopperDevicesCopy.doneOthers
        case .failed:
            return PodHopperDevicesCopy.failed
        }
    }

    /// Loads the list. Called when the screen opens and after every change.
    func load(notice newNotice: Notice = .none) {
        guard PodHopperSupabaseClient.shared.isLoggedIn() else {
            status = .loggedOut
            devices = []
            notice = .none
            return
        }
        if status != .ready {
            status = .loading
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? PodHopperDevices.shared.loadDevices()
            DispatchQueue.main.async {
                if let loaded {
                    self.devices = loaded
                    self.notice = newNotice
                    self.status = .ready
                } else if !PodHopperSupabaseClient.shared.isLoggedIn() {
                    self.devices = []
                    self.notice = .none
                    self.status = .loggedOut
                } else {
                    self.notice = .none
                    self.status = .loadFailed
                }
            }
        }
    }

    func signOut(_ device: PodHopperDevices.Device) {
        runChange(doneNotice: .doneOne) {
            _ = try PodHopperDevices.shared.signOutDevice(sessionId: device.sessionId)
        }
    }

    func signOutOthers() {
        runChange(doneNotice: .doneOthers) {
            _ = try PodHopperDevices.shared.signOutOtherDevices()
        }
    }

    private func runChange(doneNotice: Notice, change: @escaping () throws -> Void) {
        guard notice != .working else {
            return
        }
        notice = .working
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded: Bool
            do {
                try change()
                succeeded = true
            } catch {
                succeeded = false
            }
            DispatchQueue.main.async {
                // Reload either way, so the list always shows what the server now has.
                self.load(notice: succeeded ? doneNotice : .failed)
            }
        }
    }
}

/// The wording on the Signed-in devices screen. The same sentences the Android app uses.
enum PodHopperDevicesCopy {
    static let title = "Signed-in devices"
    static let loggedOut = "This shows every device signed in to your PodHopper account. Tap on the Profile page and log in first."
    static let intro = "These are the devices signed in to your PodHopper account. If you no longer have one of them, sign it out here."
    static let loading = "Loading your devices..."
    static let loadFailed = "Could not load your devices. Check your connection and try again."
    static let retry = "Try again"

    static let signOut = "Sign out"
    static let signOutOthers = "Sign out of all other devices"
    static let cancel = "Cancel"
    static let confirmOne = "Sign this device out of your PodHopper account? A car or watch clears the podcasts stored on it. A phone or tablet does too when it is signed out from here."
    static let confirmOthers = "Sign every other device out of your PodHopper account? Each one clears the podcasts stored on it and has to sign in again. This device stays signed in."
    static let working = "Signing out..."
    static let doneOne = "That device has been signed out."
    static let doneOthers = "Your other devices have been signed out."
    static let failed = "Could not sign out. Check your connection and try again."

    static let footer = "A signed-out device can keep working for up to an hour, and clears the podcasts stored on it the next time PodHopper runs on it with a connection. Devices running an older version of PodHopper show as Unknown device."

    /// For example "Car: Cadillac LYRIQ", or just the kind of device when the model is not known.
    static func name(for device: PodHopperDevices.Device) -> String {
        let kind: String
        switch device.type {
        case "phone":
            kind = "Phone"
        case "tablet":
            kind = "Tablet"
        case "car":
            kind = "Car"
        case "watch":
            kind = "Watch"
        case "unknown":
            kind = "Unknown device"
        default:
            kind = "Device"
        }
        let model = device.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? kind : kind + ": " + model
    }

    /// "This device", "Last active 5 minutes ago", or "Signed in 3 days ago".
    static func detail(for device: PodHopperDevices.Device) -> String? {
        if device.isThisDevice {
            return "This device"
        }
        if let lastActive = device.lastActiveAt {
            return "Last active " + relative(lastActive)
        }
        if let signedIn = device.signedInAt {
            return "Signed in " + relative(signedIn)
        }
        return nil
    }

    private static func relative(_ date: Date) -> String {
        // A time a moment in the future (the two clocks differ slightly) reads as "now".
        let shown = min(date, Date())
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: shown, relativeTo: Date())
    }
}
