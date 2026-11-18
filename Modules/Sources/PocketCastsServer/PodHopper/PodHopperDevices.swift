import Combine
import Foundation
import PocketCastsDataModel
import PocketCastsUtils
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

/// PodHopper: this install's place on the account's list of signed-in devices, and what happens to
/// the device when its sign-in ends. Mirrors the Android `PodHopperDevices`.
///
/// While signed in, the install keeps itself on the list (what kind of device it is, its model and
/// app version), which is what the "Signed-in devices" screen shows.
///
/// When the device ends up signed out, the rule depends on what it is:
///
///  - An Apple Watch clears the library it stored for its own sign-in, however the sign-out
///    happened: Sign out was tapped, it was removed from the list on another device, the account
///    was deleted, or the sign-in expired. A signed-out watch should never be holding someone's
///    podcasts for the next wearer to inherit. Signing in again brings the library back from the
///    account. The same check runs at every start, so a watch found signed out with a library still
///    on it is cleared then.
///
///  - An iPhone, iPad or Mac clears its library only when it was removed from the list on another
///    device. It learns that by asking the server, after the server has ended its sign-in. Logging
///    out on the device itself, or a sign-in that simply expires, leaves the library alone: the app
///    works without an account, and it may hold things that were never synced.
///
/// The host app sets the clearing handlers and calls `start` once at launch.
public final class PodHopperDevices {

    public static let shared = PodHopperDevices()

    /// One sign-in on the account, as shown on the "Signed-in devices" screen.
    public struct Device: Identifiable, Equatable {
        public let sessionId: String
        /// "phone", "tablet", "car", "watch", "other", or "unknown" for an older app version.
        public let type: String
        public let model: String
        public let appVersion: String
        public let signedInAt: Date?
        public let lastActiveAt: Date?
        public let isThisDevice: Bool

        public var id: String { sessionId }
    }

    /// Posted on the main thread once a phone, tablet or Mac has dealt with a sign-in the server ended:
    /// it has found out whether it was removed from the list on another device, and if so cleared its
    /// library. The app offers the Log in screen then.
    public static let signInEndedNotification = Notification.Name("PodHopperSignInEnded")

    /// Set by the host before `start`: removes everything an account left on this device (playback,
    /// the database, downloaded files). Called on a background queue, with the device certainly
    /// signed out and signing in held back until it returns.
    public var clearLibraryHandler: (() -> Void)?

    /// Set by the host before `start`: empties the download folders. Used when the library is already
    /// empty, in case an earlier clearing stopped after the library went but before the files did.
    public var removeDownloadedFilesHandler: (() -> Void)?

    private let supabase: PodHopperSupabaseClient
    private let dataManager: DataManager

    /// Sign-in changes are handled one at a time, in order.
    private let workQueue = DispatchQueue(label: "au.com.podhopper.devices", qos: .utility)
    /// Keeping the list up to date runs on its own, so a sign-out is never kept waiting behind it.
    private let registerQueue = DispatchQueue(label: "au.com.podhopper.devices.register", qos: .utility)

    private let stateLock = NSLock()
    private var started = false
    private var registerGeneration = 0
    private var registeredThisRun = false
    private var cachedInstallId: String?
    private var traits = DeviceTraits.unknown
    private var cancellables = Set<AnyCancellable>()

    init(supabase: PodHopperSupabaseClient = .shared, dataManager: DataManager = .sharedManager) {
        self.supabase = supabase
        self.dataManager = dataManager
    }

    // MARK: Start

    /// Starts following the sign-in state. Call once, from the main thread, at launch. The current
    /// state is handled straight away, so this also covers "the app was just started".
    public func start() {
        let deviceTraits = DeviceTraits.current()
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        traits = deviceTraits
        stateLock.unlock()

        supabase.loginState
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                self.workQueue.async {
                    if signedIn {
                        self.keepOnTheList()
                    } else {
                        self.stopKeepingOnTheList()
                        self.onSignedOut()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Call when the app comes to the front. Puts this device on the list if that has not happened
    /// since the app started (for example the sign-in could not be read when the app was started in
    /// the background).
    public func appBecameActive() {
        stateLock.lock()
        let needed = started && !registeredThisRun
        stateLock.unlock()
        if needed, supabase.isLoggedIn() {
            keepOnTheList()
        }
    }

    // MARK: Signing out

    /// Signs this device out because the person chose to: Log out, Sign out, or deleting the account
    /// (pass `tellServer: false` then, since the account and its sign-ins are already gone). Also
    /// resets this device's sync bookkeeping so a later account starts clean. The library on a phone
    /// stays; a watch clears it once the sign-out is seen.
    public func signOut(tellServer: Bool) {
        supabase.logout(tellServer: tellServer)
        resetSyncBookkeeping()
    }

    /// True when a phone, tablet or Mac should offer the Log in screen: it was signed in, the person
    /// did not sign it out, and it is certainly signed out now (a new device restored from a backup,
    /// an expired sign-in, or removed from the list on another device). Not while a sign-in the server
    /// ended is still being looked into, so a device removed from the list is cleared before it is
    /// offered a new sign-in.
    public var shouldOfferSignIn: Bool {
        supabase.expectsSignedIn && !supabase.wasEndedByServer() && supabase.signInDefinitelyAbsent()
    }

    /// The Log in screen has been offered; it is not offered again for this sign-out.
    public func signInOffered() {
        supabase.clearExpectsSignedIn()
    }

    // MARK: The list

    /// Every sign-in on the account, newest first. Refreshes this device's own entry first so it shows
    /// with its details. Blocking; throws when the list cannot be loaded.
    public func loadDevices() throws -> [Device] {
        registerNow()
        let text = try supabase.rpcText(function: "list_my_devices", body: [:])
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else {
            throw SupabaseError.requestFailed("PodHopper: the device list could not be read")
        }
        return rows.compactMap { row in
            guard let sessionId = row["session_id"] as? String, !sessionId.isEmpty else {
                return nil
            }
            return Device(
                sessionId: sessionId,
                type: row["device_type"] as? String ?? "unknown",
                model: row["model"] as? String ?? "",
                appVersion: row["app_version"] as? String ?? "",
                signedInAt: Self.parseServerTime(row["signed_in_at"] as? String),
                lastActiveAt: Self.parseServerTime(row["last_active_at"] as? String),
                isThisDevice: (row["is_current"] as? Bool) ?? false
            )
        }
    }

    /// Signs one other device out of the account. Blocking; throws on failure.
    @discardableResult
    public func signOutDevice(sessionId: String) throws -> Bool {
        let text = try supabase.rpcText(function: "sign_out_device", body: ["p_session_id": sessionId])
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Signs every other device out of the account. Returns how many. Blocking; throws on failure.
    @discardableResult
    public func signOutOtherDevices() throws -> Int {
        let text = try supabase.rpcText(function: "sign_out_other_devices", body: [:])
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Adds or refreshes this install on the list. Blocking. Returns false when it did not go through.
    @discardableResult
    public func registerNow() -> Bool {
        guard let installId = installId() else {
            return false
        }
        let deviceTraits = currentTraits()
        do {
            try supabase.rpcText(function: "register_device", body: [
                "p_install_id": installId,
                "p_device_type": deviceTraits.type,
                "p_platform": deviceTraits.platform,
                "p_model": deviceTraits.model,
                "p_app_version": Self.appVersion()
            ])
            stateLock.lock()
            registeredThisRun = true
            stateLock.unlock()
            return true
        } catch {
            FileLog.shared.addMessage("PodHopper: could not update the signed-in devices list: \(error)")
            return false
        }
    }

    // MARK: Staying on the list

    /// Puts this install on the list, retrying a few times in case the device has no connection yet.
    private func keepOnTheList() {
        stateLock.lock()
        registerGeneration += 1
        let generation = registerGeneration
        stateLock.unlock()
        attemptRegister(remainingWaits: Self.registerRetryWaits[...], generation: generation)
    }

    private func stopKeepingOnTheList() {
        stateLock.lock()
        registerGeneration += 1
        registeredThisRun = false
        stateLock.unlock()
    }

    private func attemptRegister(remainingWaits: ArraySlice<TimeInterval>, generation: Int) {
        guard let wait = remainingWaits.first else {
            return
        }
        registerQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.registerGeneration == generation
            self.stateLock.unlock()
            guard current, self.supabase.isLoggedIn() else {
                return
            }
            if self.registerNow() {
                return
            }
            self.attemptRegister(remainingWaits: remainingWaits.dropFirst(), generation: generation)
        }
    }

    // MARK: Signed out

    private func onSignedOut() {
        if currentTraits().isWatch {
            // Only when the watch certainly has no sign-in. Started in the background before it was
            // unlocked, it cannot read its sign-in at all, and that is not a sign-out.
            guard supabase.signInDefinitelyAbsent() else {
                return
            }
            clearIfSignedOut(reason: "this watch is signed out", onlyIfSomethingStored: true)
            supabase.clearEndedByServer()
            return
        }

        guard supabase.wasEndedByServer() else {
            return
        }
        // The server ended this sign-in. Was it removed from the list on purpose? If the server or
        // this device's id cannot be reached right now, the question is kept and asked again at the
        // next start.
        guard let installId = installId() else {
            return
        }
        let removedFromList: Bool
        do {
            let text = try supabase.rpcAnonText(function: "device_signed_out", body: ["p_install_id": installId])
            removedFromList = text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            FileLog.shared.addMessage("PodHopper: could not check why this sign-in ended, will ask again: \(error)")
            return
        }
        if removedFromList {
            clearIfSignedOut(reason: "removed from the signed-in devices list", onlyIfSomethingStored: false)
        }
        // Cleared last, so an interrupted clearing is repeated at the next start.
        supabase.clearEndedByServer()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.signInEndedNotification, object: nil)
        }
    }

    /// Removes everything an account left on this device, if the device is certainly signed out.
    /// Returns true when the library was cleared. Safe to repeat after being interrupted: the sync
    /// bookkeeping is reset first and last.
    @discardableResult
    private func clearIfSignedOut(reason: String, onlyIfSomethingStored: Bool) -> Bool {
        var cleared = false
        PodHopperWipeGate.shared.whileClearing {
            guard supabase.signInDefinitelyAbsent() else {
                FileLog.shared.addMessage("PodHopper: clearing skipped (\(reason)): signed in")
                return
            }
            guard let clearLibrary = clearLibraryHandler else {
                FileLog.shared.addMessage("PodHopper: clearing skipped (\(reason)): nothing set up to clear")
                return
            }
            // First, so a device stopped partway never keeps a sync position for a library it no
            // longer has.
            resetSyncBookkeeping()
            if onlyIfSomethingStored && !hasAnythingStored() {
                // Nothing in the library. Still sweep the download folders, in case an earlier
                // clearing was interrupted after the library went but before the files did.
                removeDownloadedFilesHandler?()
                return
            }
            FileLog.shared.addMessage("PodHopper: clearing this device's library: \(reason)")
            clearLibrary()
            resetSyncBookkeeping()
            cleared = true
            FileLog.shared.addMessage("PodHopper: finished clearing this device's library")
        }
        return cleared
    }

    private func hasAnythingStored() -> Bool {
        dataManager.podcastCount() > 0 ||
            !dataManager.allUpNextEpisodes().isEmpty ||
            !dataManager.findEpisodesWhere(customWhere: "1 = 1 LIMIT 1", arguments: nil).isEmpty
    }

    private func resetSyncBookkeeping() {
        PodHopperPositionSync.shared.clearLocalSyncState()
        PodHopperSubscriptionSync.shared.clearLocalSyncState()
        PodHopperUpNextSync.shared.clearLocalSyncState()
    }

    // MARK: This device

    /// A random id this install made for itself. It names the device, not the account, so it is kept
    /// across sign-outs: that is how a device that was removed from the list can find out. Kept on
    /// this device only, so a new device restored from a backup makes its own. Nil when it cannot be
    /// read right now (the device has not been unlocked since it was turned on).
    private func installId() -> String? {
        stateLock.lock()
        if let cached = cachedInstallId {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let existing: String?
        do {
            existing = try KeychainHelper.string(for: Self.installIdKey)
        } catch {
            return nil
        }
        let id: String
        if let existing, !existing.isEmpty {
            id = existing
        } else {
            let generated = UUID().uuidString.lowercased()
            guard KeychainHelper.save(string: generated, key: Self.installIdKey, accessibility: PodHopperSupabaseClient.keychainAccessibility) else {
                return nil
            }
            id = generated
        }
        stateLock.lock()
        cachedInstallId = id
        stateLock.unlock()
        return id
    }

    private func currentTraits() -> DeviceTraits {
        stateLock.lock()
        defer { stateLock.unlock() }
        return traits
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Server times look like 2026-11-18T01:43:07.00457+00:00. Nil when one cannot be read.
    static func parseServerTime(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let withoutFraction = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: withoutFraction)
    }

    /// What kind of device this is, as the list shows it. Read once, on the main thread.
    private struct DeviceTraits {
        let type: String
        let platform: String
        let model: String
        let isWatch: Bool

        static let unknown = DeviceTraits(type: "other", platform: "", model: "", isWatch: false)

        static func current() -> DeviceTraits {
            #if os(watchOS)
            return DeviceTraits(type: "watch", platform: "watchos", model: WKInterfaceDevice.current().model, isWatch: true)
            #elseif canImport(UIKit)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                return DeviceTraits(type: "other", platform: "ios", model: "Mac", isWatch: false)
            }
            let device = UIDevice.current
            let type = device.userInterfaceIdiom == .pad ? "tablet" : "phone"
            return DeviceTraits(type: type, platform: "ios", model: device.model, isWatch: false)
            #else
            return DeviceTraits(type: "other", platform: "", model: "", isWatch: false)
            #endif
        }
    }

    // MARK: Constants

    private static let installIdKey = "PodHopperInstallId"

    /// Right away, then after 30 seconds, 2 minutes and 10 minutes.
    private static let registerRetryWaits: [TimeInterval] = [0, 30, 120, 600]
}
