import Foundation
import PocketCastsUtils

/// PodHopper: Firebase Performance removed; tracing is a no-op.
class TraceHelper: TraceHandlingProtocol {
    func beginTracing(eventName: String) -> AnyObject? {
        nil
    }

    func endTracing(trace: AnyObject) {}
}
