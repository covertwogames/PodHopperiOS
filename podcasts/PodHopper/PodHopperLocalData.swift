import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UserNotifications

/// PodHopper: removes everything an account left on this iPhone, iPad or Mac. Used only when the
/// device was removed from the account's list of signed-in devices on another device (see
/// PodHopperDevices, which decides when, and calls this with the device signed out and signing in
/// held back until it returns).
///
/// What goes: playback, the podcasts and their episodes (which carry the listening history), the Up
/// Next queue, filters (the default ones are made again), folders, bookmarks, uploaded files,
/// downloaded episode files, search history, artwork caches and delivered notifications. App
/// settings stay. Nothing is removed from the account: the database is emptied directly, below the
/// hooks that report an unsubscribe or a queue change, and the device is signed out for the whole of
/// it, so no sync can run. The next sign-in starts from the account's copy, as on a new install.
enum PodHopperLocalData {

    /// Blocking, can take a few seconds. Called on a background queue.
    static func clearLibrary() {
        // Stop playback before the episode it is playing is removed. Not saved: the device is
        // signed out, and the position belongs to the library being removed.
        onMain {
            PlaybackManager.shared.endPlayback(saveCurrentEpisode: false)
        }

        // Stop downloads, so nothing lands in the folders after they are emptied.
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
        ImageManager.sharedManager.clearAllImageCaches()

        onMain {
            SearchHistoryModel.shared.removeAll()
            PlaybackManager.shared.queue.refreshList(checkForAutoDownload: false)
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)

            // Every screen that shows the library reloads.
            let center = NotificationCenter.default
            center.post(name: Constants.Notifications.opmlImportCompleted, object: nil)
            center.post(name: ServerNotifications.podcastsRefreshed, object: nil)
            center.post(name: Constants.Notifications.playlistChanged, object: nil)
            center.post(name: Constants.Notifications.folderChanged, object: nil)
            center.post(name: Constants.Notifications.manyEpisodesChanged, object: nil)
            center.post(name: Constants.Notifications.listeningHistoryChanged, object: nil)
            center.post(name: Constants.Notifications.upNextQueueChanged, object: nil)
            WidgetHelper.shared.updateAllWidgets()
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
