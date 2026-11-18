import Combine
import Foundation
import PocketCastsUtils
import Security

/// Errors from the Supabase client. `authRejected` is the GoTrue 400/401/403 case (bad credentials,
/// expired refresh token); `notSignedIn` means no refresh token is stored; `requestFailed` is any
/// other non-success or transport error.
public enum SupabaseError: Error {
    case notSignedIn
    case authRejected(String)
    case requestFailed(String)
}

/// Talks to PodHopper's Supabase backend: GoTrue auth plus PostgREST upsert and select, the car
/// pairing flow, and account deletion.
///
/// A faithful port of the Android `SupabaseClient`. The session (access token, user id, expiry) is
/// cached in memory. The refresh token and signed-in email are persisted in the Keychain, so the
/// user stays signed in across launches and the access token is silently refreshed when it expires.
///
/// PodHopper: the sign-in is kept on this device only. It is not copied to a new iPhone by a backup
/// or a phone-to-phone transfer, so a new device signs in for itself and gets its own place on the
/// account's list of signed-in devices.
///
/// Every method that hits the network is blocking; call it off the main thread. Header discipline is
/// deliberate and matters for the backend to accept the call: auth calls send only `apikey`; the
/// car pairing calls (made before the car has a user session) send `apikey` plus the anon key as a
/// bearer; authenticated REST, approve, and delete send `apikey` plus the user's access token.
public final class PodHopperSupabaseClient {

    public static let shared = PodHopperSupabaseClient()

    private let session: URLSession
    /// Serializes sign-in and token refreshes, which hold it across their network calls.
    private let lock = NSRecursiveLock()
    /// PodHopper: guards the cached session below and the stored tokens. It's only ever held briefly and
    /// never across a network call, so signing out never has to wait for the network.
    private let stateLock = NSRecursiveLock()

    private var cachedAccessToken: String?
    private var cachedUserId: String?
    private var tokenExpiresAtMs: Int64 = 0
    /// Bumped on sign-out, so a token refresh that was already out when the user signed out throws
    /// its result away instead of storing a fresh token and quietly signing them back in.
    private var sessionGeneration = 0

    private let loginStateSubject: CurrentValueSubject<Bool, Never>

    /// PodHopper: small facts about this device's sign-in (see the keys at the bottom). App settings
    /// storage, so they come along with a backup or transfer to a new device, which is the point of
    /// the "was signed in" note: a new device knows to offer the Log in screen.
    private let deviceDefaults: UserDefaults

    public init(session: URLSession = .shared) {
        self.session = session
        let defaults = UserDefaults(suiteName: Self.deviceSuiteName) ?? .standard
        Self.keepSignInOnThisDeviceOnly(defaults)
        let signedIn = !Self.keychainString(Self.refreshTokenKey).isEmpty
        if signedIn {
            defaults.set(true, forKey: Self.expectsSignedInKey)
        }
        self.deviceDefaults = defaults
        self.loginStateSubject = CurrentValueSubject<Bool, Never>(signedIn)
    }

    // MARK: Sign-in state

    public func isLoggedIn() -> Bool {
        !Self.keychainString(Self.refreshTokenKey).isEmpty
    }

    /// Emits the current sign-in state and every later change: true once a refresh token is stored
    /// (sign-in, sign-up, or pairing succeeded), false when it is cleared (sign-out or an expired
    /// session). Mirrors the Android `loginState` flow so sync components react the moment sign-in
    /// completes.
    public var loginState: AnyPublisher<Bool, Never> {
        loginStateSubject.eraseToAnyPublisher()
    }

    /// The signed-in email, or nil.
    public var signedInEmail: String? {
        let email = Self.keychainString(Self.emailKey)
        return email.isEmpty ? nil : email
    }

    // MARK: Auth

    public func login(email: String, password: String) throws {
        // PodHopper: never sign in while this device is being cleared after a sign-out.
        PodHopperWipeGate.shared.awaitIdle()
        lock.lock(); defer { lock.unlock() }
        let generation = currentGeneration
        let json = try authCall(path: "/auth/v1/token?grant_type=password", body: ["email": email, "password": password])
        try storeSignInSession(json, generation: generation, refreshToken: json["refresh_token"] as? String ?? "", email: email)
    }

    /// Creates a new account. When the project does not require email confirmation, Supabase returns
    /// a session immediately: it is applied and persisted like `login`, and this returns true. When
    /// confirmation is required, no token comes back and this returns false, which the caller
    /// surfaces as "check your email to confirm".
    @discardableResult
    public func signUp(email: String, password: String) throws -> Bool {
        PodHopperWipeGate.shared.awaitIdle()
        lock.lock(); defer { lock.unlock() }
        let generation = currentGeneration
        let json = try authCall(path: "/auth/v1/signup", body: ["email": email, "password": password])
        if json["access_token"] != nil {
            try storeSignInSession(json, generation: generation, refreshToken: json["refresh_token"] as? String ?? "", email: email)
            return true
        }
        return false
    }

    /// Asks Supabase to send a password reset email. Succeeds quietly; failures throw.
    public func recoverPassword(email: String) throws {
        _ = try authCall(path: "/auth/v1/recover", body: ["email": email])
    }

    @discardableResult
    public func ensureSession() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let cachedSession: (token: String?, generation: Int) = withStateLock { () -> (token: String?, generation: Int) in
            if let cached = cachedAccessToken, nowMs() < tokenExpiresAtMs - Self.tokenSafetyMarginMs {
                return (cached, sessionGeneration)
            }
            return (nil, sessionGeneration)
        }
        if let cached = cachedSession.token {
            return cached
        }
        let refreshToken = Self.keychainString(Self.refreshTokenKey)
        if !refreshToken.isEmpty {
            return try refreshSession(refreshToken, generation: cachedSession.generation)
        }
        throw SupabaseError.notSignedIn
    }

    public func getUserId() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        _ = try ensureSession()
        return withStateLock { cachedUserId }
    }

    /// Signs this device out because the person chose to (Log out, Sign out, or deleting the account).
    ///
    /// PodHopper: doesn't take `lock`. A token refresh holds that across a network call, and signing
    /// out, which the app does on the main thread, used to wait for it, freezing the app for as long as
    /// the request took. Bumping the generation makes a refresh that's still out discard its result.
    ///
    /// The device forgets its sign-in straight away. With `tellServer`, the server is then told in the
    /// background, so the sign-in ends there too and drops off the account's list of signed-in devices.
    /// Pass false when the server has already ended it, as when the account was just deleted.
    public func logout(tellServer: Bool = true) {
        let ending = withStateLock { () -> (accessToken: String?, refreshToken: String) in
            let accessToken = nowMs() < tokenExpiresAtMs - 5000 ? cachedAccessToken : nil
            let refreshToken = Self.keychainString(Self.refreshTokenKey)
            sessionGeneration += 1
            clearSessionCache()
            storeRefreshToken("")
            setEmail("")
            // Chosen by the person, so not a sign-out the server forced, and nothing to offer a
            // Log in screen for.
            deviceDefaults.removeObject(forKey: Self.endedByServerKey)
            deviceDefaults.removeObject(forKey: Self.expectsSignedInKey)
            return (accessToken, refreshToken)
        }
        loginStateSubject.send(false)
        if tellServer, ending.accessToken != nil || !ending.refreshToken.isEmpty {
            endSessionOnServer(accessToken: ending.accessToken, refreshToken: ending.refreshToken)
        }
    }

    /// PodHopper: called once, on the first launch after PodHopper is installed. iOS keeps an app's
    /// saved sign-in after the app is deleted, so a reinstalled app would otherwise start out signed
    /// in. Whatever sign-in an earlier install left behind is forgotten here, and ended on the server
    /// so it does not linger on the account's list, and the app starts signed out like any new
    /// install.
    public func forgetSignInLeftByEarlierInstall() {
        let leftover = withStateLock { () -> String in
            let refreshToken = Self.keychainString(Self.refreshTokenKey)
            sessionGeneration += 1
            clearSessionCache()
            storeRefreshToken("")
            setEmail("")
            deviceDefaults.removeObject(forKey: Self.endedByServerKey)
            deviceDefaults.removeObject(forKey: Self.expectsSignedInKey)
            return refreshToken
        }
        loginStateSubject.send(false)
        if !leftover.isEmpty {
            FileLog.shared.addMessage("PodHopper: forgot a sign-in left by an earlier install")
            endSessionOnServer(accessToken: nil, refreshToken: leftover)
        }
    }

    /// PodHopper: true only when this device has certainly no sign-in stored. False while the stored
    /// sign-in cannot be read, which happens when the app runs in the background before the device
    /// has been unlocked since it was turned on. Anything that deletes data because the device is
    /// signed out checks this, never `isLoggedIn`, which cannot tell the two apart.
    public func signInDefinitelyAbsent() -> Bool {
        do {
            let token = try KeychainHelper.string(for: Self.refreshTokenKey)
            return (token ?? "").isEmpty
        } catch {
            return false
        }
    }

    /// PodHopper: true when this device was signed in and has not been signed out by the person since.
    /// Signed out now with this still true means the sign-in ended some other way: it expired, it was
    /// signed out from another device, or this is a new device restored from a backup.
    public var expectsSignedIn: Bool {
        deviceDefaults.bool(forKey: Self.expectsSignedInKey)
    }

    /// PodHopper: marks the "was signed in" note as dealt with, once the Log in screen has been offered.
    public func clearExpectsSignedIn() {
        deviceDefaults.removeObject(forKey: Self.expectsSignedInKey)
    }

    /// PodHopper: true when the sign-in service itself refused this device's sign-in, so it was ended
    /// on the server rather than by the person on this device.
    public func wasEndedByServer() -> Bool {
        deviceDefaults.bool(forKey: Self.endedByServerKey)
    }

    public func clearEndedByServer() {
        deviceDefaults.removeObject(forKey: Self.endedByServerKey)
    }

    /// Tells the server this sign-in is over, in the background. A refresh token can still be swapped
    /// for a short-lived access token for this one call when no valid access token is cached. Never
    /// throws; a failure only means the sign-in lingers on the server until it is removed from the
    /// list or expires.
    private func endSessionOnServer(accessToken: String?, refreshToken: String) {
        DispatchQueue.global(qos: .utility).async {
            do {
                var token = accessToken
                if token == nil, !refreshToken.isEmpty {
                    let json = try self.authCall(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refreshToken])
                    token = json["access_token"] as? String
                }
                guard let token, !token.isEmpty else {
                    return
                }
                var request = self.makeRestRequest(url: PodHopperConfig.supabaseURL + "/auth/v1/logout?scope=local", token: token)
                request.httpMethod = "POST"
                let (_, response) = try self.performRequest(request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                FileLog.shared.addMessage("PodHopper: sign-out sent to the server: HTTP \(code)")
            } catch {
                FileLog.shared.addMessage("PodHopper: sign-out could not reach the server: \(error)")
            }
        }
    }

    // MARK: PostgREST

    public func upsert(table: String, onConflictColumns: String, rows: [[String: Any]]) throws {
        if rows.isEmpty { return }
        let url = PodHopperConfig.supabaseURL + "/rest/v1/" + table + "?on_conflict=" + onConflictColumns
        var request = try authedRestRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: rows)
        _ = try executeExpectingSuccess(request, retryOnAuthError: true)
    }

    /// Calls a Postgres function through PostgREST. The function runs as the caller, so row level
    /// security applies exactly as it does to a table request.
    public func rpc(function: String, body: [String: Any]) throws -> [String: Any] {
        let url = PodHopperConfig.supabaseURL + "/rest/v1/rpc/" + function
        var request = try authedRestRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let responseBody = try executeExpectingSuccess(request, retryOnAuthError: true)
        let parsed = try JSONSerialization.jsonObject(with: Data(responseBody.utf8))
        return (parsed as? [String: Any]) ?? [:]
    }

    /// PodHopper: calls a Postgres function whose reply is not a JSON object, and hands the reply
    /// back as text. `rpc` above can only read an object, so it throws on a function that returns
    /// nothing at all, a list, or a bare true, false or number, even though the call itself went
    /// through. Blocking; throws when the call fails.
    @discardableResult
    public func rpcText(function: String, body: [String: Any]) throws -> String {
        let url = PodHopperConfig.supabaseURL + "/rest/v1/rpc/" + function
        var request = try authedRestRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try executeExpectingSuccess(request, retryOnAuthError: true)
    }

    /// PodHopper: calls a Postgres function that anyone may call, with no sign-in, and hands the reply
    /// back as text. Used by a device that has just been signed out to ask whether it was removed from
    /// the account's list. Blocking; throws when the call fails.
    public func rpcAnonText(function: String, body: [String: Any]) throws -> String {
        var request = makeAnonRestRequest(url: PodHopperConfig.supabaseURL + "/rest/v1/rpc/" + function)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try performRequest(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if !(200...299).contains(code) {
            throw SupabaseError.requestFailed("PodHopper request failed: HTTP \(code) \(bodyStr)")
        }
        return bodyStr
    }

    public func select(table: String, query: String) throws -> [[String: Any]] {
        let url = PodHopperConfig.supabaseURL + "/rest/v1/" + table + "?" + query
        var request = try authedRestRequest(url: url)
        request.httpMethod = "GET"
        let body = try executeExpectingSuccess(request, retryOnAuthError: true)
        let parsed = try JSONSerialization.jsonObject(with: Data(body.utf8))
        return (parsed as? [[String: Any]]) ?? []
    }

    // MARK: Pairing, approve, delete

    /// Approves a car or TV pairing code on behalf of the signed-in user. Authenticated as the user.
    /// Blocking; throws on failure (invalid or expired code, or network error).
    public func approveCarPairing(code: String) throws {
        let url = PodHopperConfig.supabaseURL + "/functions/v1/pairing"
        var request = try authedRestRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "approve", "code": code])
        _ = try executeExpectingSuccess(request, retryOnAuthError: true)
    }

    /// Deletes the signed-in user's PodHopper account through the delete-account edge function, which
    /// removes their playback_state and subscriptions rows and the auth user itself. Authenticated as
    /// the user. Does not touch local on-device data: the caller logs out and clears local sync
    /// bookkeeping after this succeeds. Blocking; throws on failure.
    public func deleteAccount() throws {
        let url = PodHopperConfig.supabaseURL + "/functions/v1/delete-account"
        var request = try authedRestRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        _ = try executeExpectingSuccess(request, retryOnAuthError: true)
    }

    /// Car side of pairing, step 1. Asks for a fresh code the car displays. Anon key only. Returns
    /// the code. Blocking.
    public func startPairing(deviceName: String) throws -> String {
        let json = try pairingCall(body: ["action": "start", "device_name": deviceName])
        guard let code = json["code"] as? String else {
            throw SupabaseError.requestFailed("PodHopper pairing: missing code in response")
        }
        return code
    }

    /// Car side of pairing, step 2. Polls for the status of the code the car is showing. Returns the
    /// token_hash once the phone approves, nil while pending, throws when expired. Anon key only.
    /// Blocking.
    public func pollPairing(code: String) throws -> String? {
        let json = try pairingCall(body: ["action": "poll", "code": code])
        let status = (json["status"] as? String) ?? "pending"
        if status == "approved" {
            return json["token_hash"] as? String
        }
        if status == "expired" {
            throw SupabaseError.requestFailed("PodHopper pairing code expired")
        }
        return nil
    }

    /// Car side of pairing, step 3. Exchanges the approved token_hash for a real session through the
    /// magiclink verify endpoint (anon key, no bearer), then applies and persists that session like a
    /// normal sign-in. Storing the refresh token is what flips `isLoggedIn` to true. Blocking.
    public func claimPairingSession(tokenHash: String) throws {
        PodHopperWipeGate.shared.awaitIdle()
        lock.lock(); defer { lock.unlock() }
        let generation = currentGeneration
        clearSessionCache()
        let json = try authCall(path: "/auth/v1/verify", body: ["type": "magiclink", "token_hash": tokenHash])
        let refreshToken = json["refresh_token"] as? String ?? ""
        var email: String?
        if let user = json["user"] as? [String: Any], let userEmail = user["email"] as? String, !userEmail.isEmpty {
            email = userEmail
        }
        try storeSignInSession(json, generation: generation, refreshToken: refreshToken.isEmpty ? nil : refreshToken, email: email)
    }

    // MARK: Session internals

    /// `generation` is the session generation when the refresh began. If the user signed out while the
    /// request was out, the result is thrown away rather than stored.
    private func refreshSession(_ refreshToken: String, generation: Int) throws -> String {
        let request = try makeAuthRequest(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refreshToken])
        let (data, response) = try performRequest(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if code == 400 || code == 401 || code == 403 {
            // PodHopper: only the sign-in service itself can end a sign-in. A refusal from something
            // on the way (a network filter's block page, a gateway error) says nothing about this
            // sign-in, so it is kept and the next attempt tries again. Ending it there would sign the
            // device out, and on a watch clear its library, over a passing network problem.
            guard Self.isAuthServerError(bodyStr) else {
                throw SupabaseError.requestFailed("PodHopper sync: session refresh was refused before reaching the sign-in service: HTTP \(code)")
            }
            let isCurrentSession: Bool = withStateLock { () -> Bool in
                guard generation == sessionGeneration else { return false }
                // Written before the token is removed, so nothing sees one without the other.
                deviceDefaults.set(true, forKey: Self.endedByServerKey)
                storeRefreshToken("")
                clearSessionCache()
                return true
            }
            if isCurrentSession {
                loginStateSubject.send(false)
            }
            throw SupabaseError.requestFailed("PodHopper sign-in expired. Sign in again. (HTTP \(code) \(bodyStr))")
        }
        if !(200...299).contains(code) {
            throw SupabaseError.requestFailed("PodHopper auth failed: HTTP \(code) \(bodyStr)")
        }
        let json = parseObject(data)
        let rotated = json["refresh_token"] as? String ?? ""
        // The rotated token is stored without announcing it: the user was already signed in, and an
        // announcement sent after this lock is released could land after a sign-out's and undo it.
        let token: String? = try withStateLock { () throws -> String? in
            guard generation == sessionGeneration else {
                throw SupabaseError.notSignedIn
            }
            try applySession(json)
            if !rotated.isEmpty {
                storeRefreshToken(rotated)
            }
            return cachedAccessToken
        }
        guard let token else {
            throw SupabaseError.requestFailed("PodHopper sync: missing access token")
        }
        return token
    }

    private func applySession(_ json: [String: Any]) throws {
        guard let accessToken = json["access_token"] as? String else {
            throw SupabaseError.requestFailed("PodHopper auth: missing access token in response")
        }
        withStateLock { () -> Void in
            cachedAccessToken = accessToken
            let expiresInSec = (json["expires_in"] as? NSNumber)?.int64Value ?? 3600
            tokenExpiresAtMs = nowMs() + expiresInSec * 1000
            if let user = json["user"] as? [String: Any], let userId = user["id"] as? String, !userId.isEmpty {
                cachedUserId = userId
            } else {
                cachedUserId = nil
            }
        }
    }

    private func clearSessionCache() {
        withStateLock { () -> Void in
            cachedAccessToken = nil
            cachedUserId = nil
            tokenExpiresAtMs = 0
        }
    }

    private var currentGeneration: Int {
        withStateLock { sessionGeneration }
    }

    /// Applies a session from sign-in, sign-up or pairing, unless the user signed out after the request
    /// went out, in which case the result is thrown away instead of signing them back in. Called with
    /// `lock` held, so the announcement made here can't be reordered with another sign-in or a refresh.
    private func storeSignInSession(_ json: [String: Any], generation: Int, refreshToken: String?, email: String?) throws {
        try withStateLock { () throws -> Void in
            guard generation == sessionGeneration else {
                throw SupabaseError.notSignedIn
            }
            try applySession(json)
            if let refreshToken {
                setRefreshToken(refreshToken)
            }
            if let email {
                setEmail(email)
            }
        }
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return try body()
    }

    // MARK: Request construction (testable, no network)

    /// Auth (GoTrue) request: `apikey` only, no Authorization header. Internal for header tests.
    func makeAuthRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: PodHopperConfig.supabaseURL + path)!)
        request.httpMethod = "POST"
        request.setValue(PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Pairing edge-function request (car, pre-session): `apikey` plus the anon key as bearer.
    func makePairingRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: PodHopperConfig.supabaseURL + "/functions/v1/pairing")!)
        request.httpMethod = "POST"
        request.setValue(PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Authenticated REST/edge request: `apikey` plus the user's access token. Token is passed in so
    /// this is testable without a live session.
    func makeRestRequest(url: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// PodHopper: REST request made with no sign-in: `apikey` plus the anon key as bearer, the same as
    /// the pairing calls.
    func makeAnonRestRequest(url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + PodHopperConfig.supabaseAnonKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// PodHopper: whether a refusal came from the sign-in service itself. Its refusals are always a
    /// JSON object carrying an error code or message; anything else came from something on the way.
    static func isAuthServerError(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return object["error_code"] != nil || object["error"] != nil || object["msg"] != nil
    }

    private func authedRestRequest(url: String) throws -> URLRequest {
        let token = try ensureSession()
        return makeRestRequest(url: url, token: token)
    }

    // MARK: Network execution

    private func authCall(path: String, body: [String: Any]) throws -> [String: Any] {
        let request = try makeAuthRequest(path: path, body: body)
        let (data, response) = try performRequest(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if code == 400 || code == 401 || code == 403 {
            throw SupabaseError.authRejected("PodHopper auth failed: HTTP \(code) \(bodyStr)")
        }
        if !(200...299).contains(code) {
            throw SupabaseError.requestFailed("PodHopper auth failed: HTTP \(code) \(bodyStr)")
        }
        return parseObject(data)
    }

    private func pairingCall(body: [String: Any]) throws -> [String: Any] {
        let request = try makePairingRequest(body: body)
        let (data, response) = try performRequest(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200...299).contains(code) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.requestFailed("PodHopper pairing request failed: HTTP \(code) \(bodyStr)")
        }
        return parseObject(data)
    }

    @discardableResult
    private func executeExpectingSuccess(_ request: URLRequest, retryOnAuthError: Bool) throws -> String {
        let (data, response) = try performRequest(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if code == 401 && retryOnAuthError {
            clearSessionCache()
            let refreshed = try ensureSession()
            var retried = request
            retried.setValue("Bearer " + refreshed, forHTTPHeaderField: "Authorization")
            return try executeExpectingSuccess(retried, retryOnAuthError: false)
        }
        if !(200...299).contains(code) {
            throw SupabaseError.requestFailed("PodHopper sync request failed: HTTP \(code) \(bodyStr)")
        }
        return bodyStr
    }

    private func performRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = resultError {
            throw SupabaseError.requestFailed(error.localizedDescription)
        }
        guard let data = resultData, let response = resultResponse else {
            throw SupabaseError.requestFailed("PodHopper request: empty response")
        }
        return (data, response)
    }

    private func parseObject(_ data: Data) -> [String: Any] {
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Keychain persistence

    private static let refreshTokenKey = "PodHopperRefreshToken"
    private static let emailKey = "PodHopperEmail"

    /// PodHopper: readable once the device has been unlocked after it was turned on, like before, and
    /// kept on this device only: never copied into a backup that can be restored onto another device,
    /// or moved to a new phone by a transfer.
    static let keychainAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private static func keychainString(_ key: String) -> String {
        ((try? KeychainHelper.string(for: key)) ?? nil) ?? ""
    }

    /// PodHopper: sign-ins saved by earlier versions were stored in a way that can be copied to a new
    /// device. Each is saved again, once, so it stays on this device only. Done before anything reads
    /// it. When the stored sign-in cannot be read yet (the app was started in the background before
    /// the device was unlocked), this waits for a later launch instead of guessing.
    private static func keepSignInOnThisDeviceOnly(_ defaults: UserDefaults) {
        if defaults.bool(forKey: keptOnThisDeviceKey) {
            return
        }
        let token: String?
        let email: String?
        do {
            token = try KeychainHelper.string(for: refreshTokenKey)
            email = try KeychainHelper.string(for: emailKey)
        } catch {
            return
        }
        if let token, !token.isEmpty {
            _ = KeychainHelper.save(string: token, key: refreshTokenKey, accessibility: keychainAccessibility)
        }
        if let email, !email.isEmpty {
            _ = KeychainHelper.save(string: email, key: emailKey, accessibility: keychainAccessibility)
        }
        defaults.set(true, forKey: keptOnThisDeviceKey)
    }

    private func setRefreshToken(_ token: String) {
        storeRefreshToken(token)
        if !token.isEmpty {
            // PodHopper: a fresh sign-in. Remember the device is signed in, so a sign-in that later
            // ends without the person choosing it can be noticed, and forget any older ending.
            deviceDefaults.set(true, forKey: Self.expectsSignedInKey)
            deviceDefaults.removeObject(forKey: Self.endedByServerKey)
        }
        loginStateSubject.send(!token.isEmpty)
    }

    /// Writes or removes the stored refresh token without announcing the change.
    private func storeRefreshToken(_ token: String) {
        if token.isEmpty {
            _ = KeychainHelper.removeKey(Self.refreshTokenKey)
        } else {
            _ = KeychainHelper.save(string: token, key: Self.refreshTokenKey, accessibility: Self.keychainAccessibility)
        }
    }

    private func setEmail(_ email: String) {
        if email.isEmpty {
            _ = KeychainHelper.removeKey(Self.emailKey)
        } else {
            _ = KeychainHelper.save(string: email, key: Self.emailKey, accessibility: Self.keychainAccessibility)
        }
    }

    // MARK: Device facts (PodHopper)

    static let deviceSuiteName = "podhopper_device"
    /// The sign-in was saved again to stay on this device only (see `keepSignInOnThisDeviceOnly`).
    private static let keptOnThisDeviceKey = "sign_in_kept_on_device"
    /// This device was signed in and the person has not signed it out since.
    private static let expectsSignedInKey = "expects_signed_in"
    /// The sign-in service itself ended this device's sign-in.
    private static let endedByServerKey = "ended_by_server"

    // MARK: Helpers

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static let tokenSafetyMarginMs: Int64 = 60 * 1000
}
