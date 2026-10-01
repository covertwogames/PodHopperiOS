import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// PodHopper: the Watch app's host for the position sync engine, the counterpart of the phone's
/// PodHopperPlaybackBridge. The engine lives in PocketCastsServer and cannot see the Watch app's
/// player or episode manager, so it reaches them through this delegate.
///
/// Before this existed the Watch had no host at all: the phone's bridge is compiled into the phone
/// app only, and only the phone's AppDelegate installs it. Every apply path in the engine goes
/// through the delegate, so on the Watch none of them did anything. Positions from other devices
/// were never applied, the play-time check read the server and then applied nothing, and nothing
/// pulled after sign-in. The Watch still pushed its own positions, because pushing needs no
/// delegate, so playing an episode listened to elsewhere started from the Watch's old position and
/// its first push replaced the newer one on the server.
///
/// The Watch differs from the phone in one way that matters here: in phone mode it is a remote for
/// the phone and is not the player. So the two things that act as the player, switching the player
/// to another device's episode and publishing a position when the app goes inactive, only happen
/// in watch mode. Applying positions to the Watch's own records happens in both modes, so the
/// library is already current when the listener switches to watch mode.
///
/// Threading mirrors the phone's bridge: record writes run on the engine's queue (DataManager is
/// serialized on its own database queue), mark played and unplayed run synchronously on the main
/// thread because the engine holds its echo guard across them, and player moves are dispatched to
/// the main thread.
final class WatchPodHopperPositionHost: PodHopperPositionSyncDelegate {
    static let shared = WatchPodHopperPositionHost()

    private var reconcileTimer: Timer?

    private init() {}

    /// Install this host on the engine. Called once from ExtensionDelegate at launch. The engine
    /// holds its delegate weakly, so the shared instance is what keeps it alive.
    func install() {
        PodHopperPositionSync.shared.delegate = self
    }

    // MARK: - Apply remote state

    func updatePlayedUpTo(episode: BaseEpisode, positionSec: Double) {
        // updateSyncFlag: true bumps playedUpToModified, which the staleness guard relies on.
        DataManager.sharedManager.saveEpisode(playedUpTo: positionSec, episode: episode, updateSyncFlag: true)
    }

    func alignPausedEpisodeWithSyncedPosition(episodeUuid: String, positionSec: Double) {
        // Same rule as the phone: move the loaded episode only when it is paused, is the episode the
        // position is for, and is not already there. The sync seek never starts playback. The phone
        // also skips this while casting; the Watch has no casting.
        DispatchQueue.main.async {
            let playback = PlaybackManager.shared
            guard !playback.playing(),
                  let current = playback.currentEpisode(),
                  current.uuid == episodeUuid,
                  current.playedUpTo != positionSec
            else {
                return
            }
            playback.seekToFromSync(time: positionSec, syncChanges: false, startPlaybackAfterSeek: false)
        }
    }

    func markInProgress(episode: BaseEpisode) {
        // updateSyncFlag: true bumps playingStatusModified.
        DataManager.sharedManager.saveEpisode(playingStatus: .inProgress, episode: episode, updateSyncFlag: true)
    }

    func markAsPlayed(episode: BaseEpisode) {
        // Synchronous: the engine holds its echo guard across this call, so the completion push that
        // EpisodeManager fires must happen before this returns.
        runOnMainSync {
            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true, userInitiated: false)
        }
    }

    func markAsUnplayed(episode: BaseEpisode) {
        // Synchronous for the same reason as markAsPlayed.
        runOnMainSync {
            EpisodeManager.markAsUnplayed(episode: episode, fireNotification: true, userInitiated: false)
        }
    }

    func adoptEpisodeIntoPlayer(episode: BaseEpisode) {
        // The engine only asks after autoSwitchToCurrentEpisodeEnabled() said yes, which is watch
        // mode only. Checked again on the main thread in case the mode changed in between.
        DispatchQueue.main.async {
            guard SourceManager.shared.isWatch() else { return }
            PlaybackManager.shared.adoptCurrentEpisodeFromSync(episode: episode)
        }
    }

    // MARK: - Read local state

    func currentlyPlayingEpisodeUuid() -> String? {
        guard PlaybackManager.shared.playing() else { return nil }
        return PlaybackManager.shared.currentEpisode()?.uuid
    }

    func currentEpisodeForPush() -> (episode: BaseEpisode, positionMs: Int, durationMs: Int)? {
        // In phone mode the Watch is not the player, so its loaded episode and position are not
        // what the listener is hearing. Publishing them would replace a newer position from the
        // phone with the Watch's old one. Nothing to push unless the Watch is the player.
        guard SourceManager.shared.isWatch() else { return nil }
        guard let episode = PlaybackManager.shared.currentEpisode() else { return nil }
        let positionMs = Int(PlaybackManager.shared.currentTime() * 1000)
        let durationMs = Int(PlaybackManager.shared.duration() * 1000)
        return (episode, positionMs, durationMs)
    }

    func autoSwitchToCurrentEpisodeEnabled() -> Bool {
        // Switching the Watch's player to the episode another device was last playing only makes
        // sense when the Watch is the player. The phone's own setting lives in the phone's storage,
        // which the Watch cannot read.
        SourceManager.shared.isWatch()
    }

    // MARK: - App lifecycle

    /// The Watch app became active: reconcile with the freshest cross-device state now, and every
    /// 30 seconds while it stays active, matching the phone's foreground timer. The engine
    /// self-throttles and self-guards on sign-in, so a tick is cheap when there is nothing to do.
    func becameActive() {
        PodHopperPositionSync.shared.reconcileNowPlaying()
        startReconcileTimer()
    }

    /// The Watch app is going inactive (wrist down, another app): publish the latest position, which
    /// only happens in watch mode (see currentEpisodeForPush), and stop the timer.
    func willResignActive() {
        PodHopperPositionSync.shared.pushCurrentPosition(immediate: true)
        stopReconcileTimer()
    }

    // MARK: - Helpers

    private func startReconcileTimer() {
        stopReconcileTimer()
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            PodHopperPositionSync.shared.reconcileNowPlaying()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private func stopReconcileTimer() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }

    private func runOnMainSync(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
}
