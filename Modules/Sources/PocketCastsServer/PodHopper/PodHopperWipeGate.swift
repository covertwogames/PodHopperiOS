import Foundation

/// PodHopper: keeps a sign-in from starting while this device is being cleared after a sign-out.
///
/// Clearing runs inside `whileClearing`. Signing in, creating an account and claiming a car or watch
/// code call `awaitIdle` first, so a library being removed can never be mixed with the library of
/// the next sign-in. The wait is bounded, so a clearing that is somehow stuck cannot block signing in
/// for good.
public final class PodHopperWipeGate {

    public static let shared = PodHopperWipeGate()

    /// Held for the whole of a clearing, and only then.
    private let lock = NSLock()

    /// Runs `body` with the gate closed. `body` must be synchronous: the lock is taken and released
    /// on the calling thread.
    public func whileClearing(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    /// Returns once no clearing is running, or after 20 seconds at most. Blocking; call off the main
    /// thread.
    public func awaitIdle() {
        if lock.lock(before: Date().addingTimeInterval(20)) {
            lock.unlock()
        }
    }
}
