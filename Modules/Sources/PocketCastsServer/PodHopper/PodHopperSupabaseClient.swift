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
/// Every method that hits the network is blocking; call it off the main thread. Header discipline is
/// deliberate and matters for the backend to accept the call: auth calls send only `apikey`; the
/// car pairing calls (made before the car has a user session) send `apikey` plus the anon key as a
/// bearer; authenticated REST, approve, and delete send `apikey` plus the user's access token.
public final class PodHopperSupabaseClient {

    public static let shared = PodHopperSupabaseClient()

    private let session: URLSession
    private let lock = NSRecursiveLock()

    private var cachedAccessToken: String?
    private var cachedUserId: String?
    private var tokenExpiresAtMs: Int64 = 0

    private let loginStateSubject: CurrentValueSubject<Bool, Never>

    public init(session: URLSession = .shared) {
        self.session = session
        self.loginStateSubject = CurrentValueSubject<Bool, Never>(!Self.keychainString(Self.refreshTokenKey).isEmpty)
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
        lock.lock(); defer { lock.unlock() }
        let json = try authCall(path: "/auth/v1/token?grant_type=password", body: ["email": email, "password": password])
        try applySession(json)
        setRefreshToken(json["refresh_token"] as? String ?? "")
        setEmail(email)
    }

    /// Creates a new account. When the project does not require email confirmation, Supabase returns
    /// a session immediately: it is applied and persisted like `login`, and this returns true. When
    /// confirmation is required, no token comes back and this returns false, which the caller
    /// surfaces as "check your email to confirm".
    @discardableResult
    public func signUp(email: String, password: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let json = try authCall(path: "/auth/v1/signup", body: ["email": email, "password": password])
        if json["access_token"] != nil {
            try applySession(json)
            setRefreshToken(json["refresh_token"] as? String ?? "")
            setEmail(email)
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
        if let cached = cachedAccessToken, nowMs() < tokenExpiresAtMs - Self.tokenSafetyMarginMs {
            return cached
        }
        let refreshToken = Self.keychainString(Self.refreshTokenKey)
        if !refreshToken.isEmpty {
            return try refreshSession(refreshToken)
        }
        throw SupabaseError.notSignedIn
    }

    public func getUserId() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        _ = try ensureSession()
        return cachedUserId
    }

    public func logout() {
        lock.lock(); defer { lock.unlock() }
        clearSessionCache()
        setRefreshToken("")
        setEmail("")
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
        lock.lock(); defer { lock.unlock() }
        clearSessionCache()
        let json = try authCall(path: "/auth/v1/verify", body: ["type": "magiclink", "token_hash": tokenHash])
        try applySession(json)
        let refreshToken = json["refresh_token"] as? String ?? ""
        if !refreshToken.isEmpty {
            setRefreshToken(refreshToken)
        }
        if let user = json["user"] as? [String: Any], let email = user["email"] as? String, !email.isEmpty {
            setEmail(email)
        }
    }

    // MARK: Session internals

    private func refreshSession(_ refreshToken: String) throws -> String {
        let json: [String: Any]
        do {
            json = try authCall(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refreshToken])
        } catch SupabaseError.authRejected(let message) {
            setRefreshToken("")
            throw SupabaseError.requestFailed("PodHopper sign-in expired. Sign in again. (\(message))")
        }
        try applySession(json)
        let rotated = json["refresh_token"] as? String ?? ""
        if !rotated.isEmpty {
            setRefreshToken(rotated)
        }
        guard let token = cachedAccessToken else {
            throw SupabaseError.requestFailed("PodHopper sync: missing access token")
        }
        return token
    }

    private func applySession(_ json: [String: Any]) throws {
        guard let accessToken = json["access_token"] as? String else {
            throw SupabaseError.requestFailed("PodHopper auth: missing access token in response")
        }
        cachedAccessToken = accessToken
        let expiresInSec = (json["expires_in"] as? NSNumber)?.int64Value ?? 3600
        tokenExpiresAtMs = nowMs() + expiresInSec * 1000
        if let user = json["user"] as? [String: Any], let userId = user["id"] as? String, !userId.isEmpty {
            cachedUserId = userId
        } else {
            cachedUserId = nil
        }
    }

    private func clearSessionCache() {
        cachedAccessToken = nil
        cachedUserId = nil
        tokenExpiresAtMs = 0
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

    private static func keychainString(_ key: String) -> String {
        ((try? KeychainHelper.string(for: key)) ?? nil) ?? ""
    }

    private func setRefreshToken(_ token: String) {
        if token.isEmpty {
            _ = KeychainHelper.removeKey(Self.refreshTokenKey)
        } else {
            _ = KeychainHelper.save(string: token, key: Self.refreshTokenKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
        }
        loginStateSubject.send(!token.isEmpty)
    }

    private func setEmail(_ email: String) {
        if email.isEmpty {
            _ = KeychainHelper.removeKey(Self.emailKey)
        } else {
            _ = KeychainHelper.save(string: email, key: Self.emailKey, accessibility: kSecAttrAccessibleAfterFirstUnlock)
        }
    }

    // MARK: Helpers

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static let tokenSafetyMarginMs: Int64 = 60 * 1000
}
