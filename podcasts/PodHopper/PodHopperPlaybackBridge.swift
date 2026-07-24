import Foundation
import UIKit
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

    private var lifecycleObserversRegistered = false
    private var reconcileTimer: Timer?

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
        // Synchronous: the engine holds its echo guard across this call, so the completion push
        // that EpisodeManager fires must happen before this returns. EpisodeManager stamps
        // playingStatusModified itself, which is what the staleness guard compares against.
        runOnMainSync {
            EpisodeManager.markAsPlayed(episode: episode, fireNotification: true, userInitiated: false)
        }
    }

    func markAsUnplayed(episode: BaseEpisode) {
        // Synchronous for the same reason as markAsPlayed: un-marking now pushes, so the echo guard
        // has to still be held when that push is skipped.
        runOnMainSync {
            EpisodeManager.markAsUnplayed(episode: episode, fireNotification: true, userInitiated: false)
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

    // MARK: - App lifecycle

    /// Registers foreground/background observers. Idempotent. Called once from configure().
    func startObservingLifecycle() {
        if lifecycleObserversRegistered { return }
        lifecycleObserversRegistered = true
        // willEnterForeground (not didBecomeActive) so a transient interruption such as a phone call
        // or Control Center does not trigger a pull-and-adopt. Cold launch does not fire this, so the
        // initial foreground sync is run directly from configure().
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    /// Reconcile cross-device positions (switching to the most recent episode when the setting is on)
    /// and run the subscription poll loop while the app is in the foreground, and start the 30s
    /// reconcile timer so progress made on another device keeps appearing while the app stays open.
    /// Safe to call when signed out: every engine call self-guards on the login state.
    func foregroundSync() {
        PodHopperPositionSync.shared.reconcileNowPlaying()
        PodHopperSubscriptionSync.shared.startPeriodicSync()
        startReconcileTimer()
    }

    @objc private func appWillEnterForeground() {
        foregroundSync()
    }

    @objc private func appDidEnterBackground() {
        // Push the latest position so other devices resume exactly where this one left off, then stop
        // the foreground poll loop and the reconcile timer. The push is best-effort: the periodic and
        // pause pushes already keep the server fresh, so this is a last-position safety net.
        PodHopperPositionSync.shared.pushCurrentPosition(immediate: true)
        PodHopperSubscriptionSync.shared.stopPeriodicSync()
        stopReconcileTimer()
    }

    // MARK: - Helpers

    /// Starts (or restarts) the foreground reconcile timer: every 30 seconds while the app is open,
    /// reconcile the now-playing window with the freshest cross-device state. Mirrors the Android
    /// RECONCILE_INTERVAL_MS timer. The engine self-throttles and self-guards on login, so a tick is
    /// cheap when there is nothing to do. Cancelled when the app backgrounds. Main thread only.
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

        PodHopperPlaybackBridge.shared.startObservingLifecycle()
        // Cold launch counts as entering the foreground, but willEnterForeground does not fire on
        // launch, so run the initial foreground sync here.
        PodHopperPlaybackBridge.shared.foregroundSync()
    }
}
