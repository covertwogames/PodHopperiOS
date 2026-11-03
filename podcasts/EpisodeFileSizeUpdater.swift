import AVFoundation
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

class EpisodeFileSizeUpdater {
    class func updateEpisodeDuration(episode: BaseEpisode?) {
        guard let episode else { return }

        let fileLocation = episode.pathToDownloadedFile(pathFinder: DownloadManager.shared)
        let url = URL(fileURLWithPath: fileLocation)
        let asset = AVURLAsset(url: url)

        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            let status = asset.statusOfValue(forKey: "duration", error: nil)
            if status == .loaded {
                let calculatedDuration = CMTimeGetSeconds(asset.duration)
                // An indefinite or invalid duration comes back as NaN or infinity, which passes the range
                // check below and then crashes converting to Int.
                guard calculatedDuration.isFinite else { return }
                if calculatedDuration < 10 || calculatedDuration > 36000 { return } // duration is too short or too long to be a podcast eg: less than 10 seconds or more than 10 hours

                let currentDuration = episode.duration
                // Int(safeDouble:) because a duration saved from a feed before durations were checked can be NaN
                // or infinite, which Int(_:) crashes on.
                if Int(safeDouble: currentDuration) == Int(safeDouble: calculatedDuration) { return } // we already have the correct duration

                var syncChanges = true
                if abs(currentDuration - calculatedDuration) < 30 {
                    // only a minor change so just update the db but don't bother syncing
                    syncChanges = false
                }

                DataManager.sharedManager.saveEpisode(duration: calculatedDuration, episode: episode, updateSyncFlag: syncChanges)
                NotificationCenter.postOnMainThread(notification: Constants.Notifications.episodeDurationChanged, object: episode.uuid)
            }
        }
    }
}
