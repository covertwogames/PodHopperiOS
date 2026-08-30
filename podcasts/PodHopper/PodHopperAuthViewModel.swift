import Foundation
import Combine
import PocketCastsServer

/// Drives PodHopper's sign-in / sign-up / password-recovery / account screens. Mirrors the Android
/// PodHopperOnboardingViewModel: the same actions, the same state transitions, and the same
/// extraction of Supabase's human-readable error message.
final class PodHopperAuthViewModel: ObservableObject {
    enum Mode {
        case login
        case signup
        case recover
        case account
    }

    enum Status: Equatable {
        case idle
        case busy
        case error(String)
        case confirmEmail
        case recoverSent
    }

    @Published var mode: Mode
    @Published var status: Status = .idle

    private let supabase = PodHopperSupabaseClient.shared

    /// Called after a real session is established (sign in, or sign up that returns a session).
    var onAuthenticated: (() -> Void)?
    /// Called after logout, and when the user closes the screen.
    var onClose: (() -> Void)?

    init() {
        mode = PodHopperSupabaseClient.shared.isLoggedIn() ? .account : .login
    }

    var isSignedIn: Bool { supabase.isLoggedIn() }
    var signedInEmail: String { supabase.signedInEmail ?? "" }

    func resetStatus() {
        status = .idle
    }

    func signIn(email: String, password: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            status = .error("Enter your email and password.")
            return
        }
        status = .busy
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.supabase.login(email: trimmed, password: password)
                DispatchQueue.main.async {
                    self.status = .idle
                    self.onAuthenticated?()
                }
            } catch SupabaseError.authRejected {
                DispatchQueue.main.async { self.status = .error("Incorrect email or password.") }
            } catch {
                DispatchQueue.main.async {
                    self.status = .error(Self.serverMessage(error) ?? "Couldn't log in. Please try again.")
                }
            }
        }
    }

    func signUp(email: String, password: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            status = .error("Enter your email and password.")
            return
        }
        status = .busy
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let sessionActive = try self.supabase.signUp(email: trimmed, password: password)
                DispatchQueue.main.async {
                    if sessionActive {
                        self.status = .idle
                        self.onAuthenticated?()
                    } else {
                        self.status = .confirmEmail
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .error(Self.serverMessage(error) ?? "Couldn't create your account. Please try again.")
                }
            }
        }
    }

    func recoverPassword(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.contains(".") else {
            status = .error("Enter a valid email address.")
            return
        }
        status = .busy
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.supabase.recoverPassword(email: trimmed)
                DispatchQueue.main.async { self.status = .recoverSent }
            } catch {
                DispatchQueue.main.async {
                    self.status = .error(Self.serverMessage(error) ?? "Couldn't send the reset email. Please try again.")
                }
            }
        }
    }

    func logout() {
        supabase.logout()
        // Clear both sync engines so the next account starts clean.
        PodHopperPositionSync.shared.clearLocalSyncState()
        PodHopperSubscriptionSync.shared.clearLocalSyncState()
        PodHopperUpNextSync.shared.clearLocalSyncState()
        onClose?()
    }

    /// Pulls Supabase's human-readable message out of an error that may carry a JSON body, so the UI
    /// shows one clean sentence rather than an HTTP dump. Returns nil when there is no such message.
    static func serverMessage(_ error: Error) -> String? {
        let raw: String
        switch error {
        case SupabaseError.authRejected(let message), SupabaseError.requestFailed(let message):
            raw = message
        default:
            raw = "\(error)"
        }
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["msg", "error_description", "message", "error"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
