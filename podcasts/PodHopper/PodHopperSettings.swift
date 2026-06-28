import Foundation

extension Settings {
    private static let podhopperAutoSwitchPlayerToCurrentPodcastKey = "podhopperAutoSwitchPlayerToCurrentPodcast"

    /// When enabled, opening the app switches the player to the most recent in-progress episode
    /// played on another device (paused at its synced position). Opt-out: defaults to ON when the
    /// user has never set it.
    static var autoSwitchPlayerToCurrentPodcast: Bool {
        get {
            if UserDefaults.standard.object(forKey: podhopperAutoSwitchPlayerToCurrentPodcastKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: podhopperAutoSwitchPlayerToCurrentPodcastKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: podhopperAutoSwitchPlayerToCurrentPodcastKey)
        }
    }
}
