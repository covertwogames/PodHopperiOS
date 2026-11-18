import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// PodHopper: removes the library this Apple Watch stored for its own sign-in. PodHopperDevices calls
/// it whenever the watch ends up signed out, for any reason, with the watch signed out and signing in
/// held back until it returns.
///
/// What goes: playback on the watch, the podcasts and episodes it synced, its Up Next, filters (the
/// default ones are made again) and downloaded episodes. Nothing is removed from the account, and
/// what the watch shows from the iPhone is untouched: afterwards the watch plays from the phone, as
/// it does whenever it is signed out.
enum WatchLocalData {

    /// Blocking, can take a few seconds. Called on a background queue.
    static func clearLibrary() {
        onMain {
            PlaybackManager.shared.endPlayback(saveCurrentEpisode: false)
        }

        let downloadsStopped = DispatchSemaphore(value: 0)
        Task {
            for task in await DownloadManager.shared.allTasks() {
                task.cancel()
            }
            downloadsStopped.signal()
        }
        _ = downloadsStopped.wait(timeout: .now() + 10)

        DataManager.sharedManager.deleteAllData()
        PlaylistManager.createDefaultPlaylists()
        DownloadManager.shared.removeAllDownloadedFiles()

        onMain {
            PlaybackManager.shared.queue.refreshList(checkForAutoDownload: false)
            SourceManager.shared.setSource(newSource: .phone)

            let center = NotificationCenter.default
            center.post(name: ServerNotifications.podcastsRefreshed, object: nil)
            center.post(name: Constants.Notifications.playlistChanged, object: nil)
            center.post(name: Constants.Notifications.upNextQueueChanged, object: nil)
        }
    }

    /// Empties the download folders. Called on a background queue.
    static func removeDownloadedFiles() {
        DownloadManager.shared.removeAllDownloadedFiles()
    }

    private static func onMain(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}
