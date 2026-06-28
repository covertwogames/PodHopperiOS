import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// App-side bridge that lets the PodHopper position sync engine (which lives in PocketCastsServer and
/// therefore cannot see the app's PlaybackManager / EpisodeManager) drive real playback and episode
/// state on this device.
///
/// Threading notes:
/// - The engine calls the apply-side methods synchronously while holding its echo guard, so anything
///   that could trigger a push back to the server must finish before the method returns. markAsPlayed
///   therefore runs synchronously (it also touches the player, so it runs on the main thread).
/// - updatePlayedUpTo / markInProgress are pure DataManager writes. DataManager is serialized on its
///   own database queue, so they are safe to run directly from the engine's background work queue and
///   they do not touch the player.
/// - adoptEpisodeIntoPlayer changes the now-playing episode, so it is dispatched to the main thread.
final class PodHopperPlaybackBridge: PodHopperPositionSyncDelegate {
    static let shared = PodHopperPlaybackBridge()

    private init() {}

    // MARK: - Apply remote state

    func updatePlayedUpTo(episode: BaseEpisode, positionSec: Double) {
        // updateSyncFlag: true bumps playedUpToModified, which the staleness guard relies on.
        DataManager.sharedManager.saveEpisode(playedUpTo: positionSec, episode: episode, updateSyncFlag: true)
    }

    func markInProgress(episode: BaseEpisode) {
        // updateSyncFlag: true bumps playingStatusModified.
        DataManager.sharedManager.saveEpisode(playingStatus: .inProgress, episode: episode, updateSyncFlag: true)
    }

    func markAsPlayed(episode: BaseEpisode) {
        runOnMainSync {
            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true, userInitiated: false)
            // markAsPlayed only bumps playingStatusModified when the Pocket Casts sync is logged in,
            // which PodHopper never is. Bump it explicitly so the completion is timestamped and the
            // staleness guard protects it on the next pull.
            DataManager.sharedManager.saveEpisode(playingStatus: .completed, episode: episode, updateSyncFlag: true)
        }
    }

    func adoptEpisodeIntoPlayer(episode: BaseEpisode) {
        DispatchQueue.main.async {
            PlaybackManager.shared.adoptCurrentEpisodeFromSync(episode: episode)
        }
    }

    // MARK: - Read local state

    func currentlyPlayingEpisodeUuid() -> String? {
        guard PlaybackManager.shared.playing() else { return nil }
        return PlaybackManager.shared.currentEpisode()?.uuid
    }

    func currentEpisodeForPush() -> (episode: BaseEpisode, positionMs: Int, durationMs: Int)? {
        guard let episode = PlaybackManager.shared.currentEpisode() else { return nil }
        let positionMs = Int(PlaybackManager.shared.currentTime() * 1000)
        let durationMs = Int(PlaybackManager.shared.duration() * 1000)
        return (episode, positionMs, durationMs)
    }

    func autoSwitchToCurrentEpisodeEnabled() -> Bool {
        Settings.autoSwitchPlayerToCurrentPodcast
    }

    // MARK: - Helpers

    private func runOnMainSync(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
}

/// One-time wiring of the PodHopper sync engines to their app-side hosts. Called from
/// AppDelegate.didFinishLaunching. Referencing the engines' shared instances here also starts their
/// sign-in observers.
enum PodHopperSyncSetup {
    static func configure() {
        PodHopperPositionSync.shared.delegate = PodHopperPlaybackBridge.shared

        PodHopperSubscriptionSync.shared.unsubscribeHandler = { uuid in
            if let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
                PodcastManager.shared.unsubscribe(podcast: podcast)
            }
        }
    }
}
