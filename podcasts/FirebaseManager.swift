import Foundation
import PocketCastsUtils

/// PodHopper: Firebase Remote Config removed. The app always runs on the built-in defaults
/// defined in Constants.RemoteParams and each FeatureFlag's `default` value. This stub keeps
/// the existing call sites compiling; the completion fires immediately, matching the behavior
/// of a successful fetch that changed nothing.
struct FirebaseManager {
    static func refreshRemoteConfig(expirationDuration: TimeInterval = 2.hour, completion: ((Bool) -> Void)? = nil) {
        completion?(true)
    }
}
