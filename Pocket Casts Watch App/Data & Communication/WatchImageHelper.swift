import Kingfisher
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import WatchKit

class WatchImageHelper {
    static let shared = WatchImageHelper()

    // Discover Cache
    var mainCache = ImageCache(name: "mainCache")

    init() {
        mainCache.diskStorage.config.sizeLimit = UInt(30.megabytes)
        mainCache.diskStorage.config.expiration = .days(45)
        // the Series 3 Apple watch is slower and has tighter resources, so set our settings there a bit more aggressively
        if DeviceUtil.identifier.lowercased().startsWith(string: "watch3") {
            mainCache.memoryStorage.config.totalCostLimit = Int(1.megabytes)
            mainCache.memoryStorage.config.expiration = .seconds(2.minutes)
        } else {
            mainCache.memoryStorage.config.totalCostLimit = Int(5.megabytes)
            mainCache.memoryStorage.config.expiration = .seconds(10.minutes)
        }
    }

    /// Single source of truth for a podcast's artwork URL on the watch. PodHopper feed podcasts carry
    /// their own artwork url from the RSS feed, so use it directly instead of the Pocket Casts image
    /// server, which has no entry for feed podcasts. Falls back to the Pocket Casts server only when a
    /// podcast has no feed artwork. Mirrors the phone's ImageManager.podcastImageURL.
    class func podcastImageURL(podcastUuid: String, size: Int) -> URL {
        if let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true),
           let feedArtwork = podcast.imageURL,
           !feedArtwork.isEmpty,
           let feedArtworkUrl = URL(string: feedArtwork) {
            return feedArtworkUrl
        }

        return ServerHelper.imageUrl(podcastUuid: podcastUuid, size: size)
    }

    class func imageUrl(size: Int, podcastUuid: String) -> String {
        podcastImageURL(podcastUuid: podcastUuid, size: size).absoluteString
    }

    class func largeImageUrl(episode: BaseEpisode) -> URL {
        if let userEpisode = episode as? UserEpisode {
            return userEpisode.urlForImage(size: 960)
        }

        return podcastImageURL(podcastUuid: episode.parentIdentifier(), size: 340)
    }
}
