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
    /// their own artwork url from the RSS feed, so use it directly. When a podcast has no feed
    /// artwork, ServerHelper.imageUrl returns a file that never exists, so the placeholder shows and
    /// no server is contacted. Mirrors the phone's ImageManager.podcastImageURL.
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

    /// The watch never shows artwork larger than this many pixels, which is also the largest podcast artwork
    /// size it downloaded before it switched to feed artwork. Feed artwork is often 3000x3000, about 36 MB
    /// once decoded, which is more than the watch app is allowed to use.
    static let maxArtworkPixelSize: CGFloat = 340
}

/// Decodes downloaded artwork at no more than `WatchImageHelper.maxArtworkPixelSize` pixels on its longest
/// side. It keeps the default processor's empty identifier on purpose, so Kingfisher's cache keys stay the
/// same and artwork already cached on the watch is still found.
struct WatchArtworkImageProcessor: ImageProcessor {
    static let shared = WatchArtworkImageProcessor()

    let identifier = DefaultImageProcessor.default.identifier

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case .image:
            return DefaultImageProcessor.default.process(item: item, options: options)
        case .data(let data):
            return ImageDownsampler.downsampledImage(from: data, maxPixelSize: WatchImageHelper.maxArtworkPixelSize, scale: options.scaleFactor)
                ?? DefaultImageProcessor.default.process(item: item, options: options)
        }
    }
}

/// Reads artwork back from the disk cache at no more than `WatchImageHelper.maxArtworkPixelSize`, including
/// full size artwork cached before that limit existed. Writes to disk the way Kingfisher always has, which
/// now saves the smaller copy, so the watch's small disk cache holds more artwork. If that copy can't be
/// encoded, the downloaded file is saved instead.
struct WatchArtworkCacheSerializer: CacheSerializer {
    static let shared = WatchArtworkCacheSerializer()

    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        DefaultCacheSerializer.default.data(with: image, original: original) ?? original
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        ImageDownsampler.downsampledImage(from: data, maxPixelSize: WatchImageHelper.maxArtworkPixelSize, scale: options.scaleFactor)
            ?? DefaultCacheSerializer.default.image(with: data, options: options)
    }
}
