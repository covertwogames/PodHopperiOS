import Foundation
import PocketCastsServer
import PocketCastsUtils

/// PodHopper: keeps track of whether the person using this iPhone or iPad has agreed to the current
/// Terms of Service, and copies that agreement onto their account when they have one. Mirrors the
/// Android `PodHopperTerms`.
///
/// Two records exist on purpose:
///
///  - On this device: which version was agreed to, when, and how (the sign-up checkbox, the notice
///    on the log in or no-account path, or the one-time screen shown to people who were already
///    using the app). This is what decides whether the one-time screen is shown, so it works with
///    no account and with no connection.
///
///  - On the account: the same facts, sent once per account through the accept_terms function.
///    The server stamps its own time on the row and keeps the first record for each version.
///
/// Only the phone and tablet app records agreement. The watch cannot create accounts; it shows a
/// notice on its sign-in screen instead. CarPlay has no sign-in of its own.
final class PodHopperTerms {

    static let shared = PodHopperTerms()

    /// How the agreement was given. The raw values are what the account record stores, and they are
    /// the same words the Android app sends.
    enum Method: String {
        /// Ticked the box while creating an account.
        case checkbox
        /// Tapped Agree on the one-time screen shown to people already using the app.
        case prompt
        /// Logged in on a screen that says logging in means agreeing.
        case signIn = "signin"
        /// Chose to continue without an account on a screen that says continuing means agreeing.
        case notice
    }

    /// The effective date of the Terms this build was made for. Change it only when the Terms
    /// themselves change: a new value shows the one-time screen to everyone again.
    static let termsVersion = "2026-07-01"

    static let termsAddress = "https://podhopper.app/terms"
    static let privacyAddress = "https://podhopper.app/privacy"
    static let termsURL = URL(string: termsAddress)!
    static let privacyURL = URL(string: privacyAddress)!

    private let supabase: PodHopperSupabaseClient
    private let defaults: UserDefaults

    /// One at a time, so two triggers close together cannot both send the same record.
    private let syncQueue = DispatchQueue(label: "au.com.podhopper.terms", qos: .utility)
    private let recordLock = NSLock()

    init(
        supabase: PodHopperSupabaseClient = .shared,
        defaults: UserDefaults = UserDefaults(suiteName: PodHopperTerms.suiteName) ?? .standard
    ) {
        self.supabase = supabase
        self.defaults = defaults
    }

    /// True until the current version of the Terms has been agreed to on this device.
    var needsAgreement: Bool {
        defaults.string(forKey: Self.versionKey) != Self.termsVersion
    }

    /// Records that the current Terms were agreed to on this device just now.
    ///
    /// An agreement that is still waiting to be copied to an account is left as it is. That keeps
    /// the original moment and method when someone ticks the box to create an account, has to
    /// confirm their email first, and only then logs in.
    func recordAgreement(method: Method) {
        recordLock.lock()
        defer { recordLock.unlock() }

        let alreadyAgreed = defaults.string(forKey: Self.versionKey) == Self.termsVersion
        let waitingForAccount = defaults.string(forKey: Self.uploadedForKey) == nil
        if alreadyAgreed && waitingForAccount {
            return
        }
        defaults.set(Self.termsVersion, forKey: Self.versionKey)
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Self.agreedAtMsKey)
        defaults.set(method.rawValue, forKey: Self.methodKey)
        defaults.removeObject(forKey: Self.uploadedForKey)
    }

    /// Runs `syncToAccount` in the background. Safe to call from the main thread, and often.
    func syncToAccountAsync() {
        syncQueue.async {
            self.syncToAccount()
        }
    }

    /// Copies this device's agreement onto the signed-in account, once per account. Does nothing
    /// when nobody is signed in, when nothing has been agreed to, or when it was already sent for
    /// this account. Blocking network call; never throws. A failed attempt is simply tried again
    /// the next time this is called.
    func syncToAccount() {
        if needsAgreement || !supabase.isLoggedIn() {
            return
        }
        // Which account it was sent for is remembered as a hash, so the email address itself is not
        // written into the app's settings.
        let accountKey = Self.termsVersion + "|" + (supabase.signedInEmail ?? "").lowercased().sha256
        if defaults.string(forKey: Self.uploadedForKey) == accountKey {
            return
        }

        var params: [String: Any] = [
            "p_version": Self.termsVersion,
            "p_platform": "ios",
            "p_app_version": Settings.appVersion(),
            "p_method": defaults.string(forKey: Self.methodKey) ?? Method.notice.rawValue
        ]
        let agreedAtMs = defaults.double(forKey: Self.agreedAtMsKey)
        if agreedAtMs > 0 {
            params["p_accepted_at"] = Self.isoUTC(agreedAtMs)
        }

        do {
            try supabase.rpcText(function: "accept_terms", body: params)
            defaults.set(accountKey, forKey: Self.uploadedForKey)
            FileLog.shared.addMessage("PodHopper: Terms agreement saved to the account (version \(Self.termsVersion))")
        } catch {
            FileLog.shared.addMessage("PodHopper: Terms agreement not saved to the account yet: \(error)")
        }
    }

    /// For example 2026-11-18T03:31:07Z.
    private static func isoUTC(_ timeMs: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timeMs / 1000))
    }

    // MARK: Constants

    static let suiteName = "podhopper_terms"
    private static let versionKey = "agreed_version"
    private static let agreedAtMsKey = "agreed_at_ms"
    private static let methodKey = "agreed_method"
    private static let uploadedForKey = "uploaded_for"
}
