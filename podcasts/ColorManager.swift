import PocketCastsUtils
import PocketCastsDataModel
import PocketCastsServer
import UIKit

class ColorManager {
    private let defaultBackgroundColor = UIColor(hex: "#3D3D3D")
    private let defaultLightTintColor = UIColor(hex: "#1E1F1E")
    private let defaultDarkTintColor = UIColor(hex: "#FFFFFF")

    private let defaultServerLightTint = "#F44336"
    private let defaultServerDarkTint = "#C62828"

    // the amount of time to leave between color refresh attempts. This is quite low (30 min) because we write out defaults for shows that are missing artwork, so this should always be present
    private let minTimeBetweenColorRefreshAttempts = 30.minutes

    private let currentColorVersion = 4 as Int32

    private let colorDownloadQueue = OperationQueue()

    private let lock = NSObject()
    private var downloadingPodcasts = [String]()

    static let sharedManager = ColorManager()

    private init() {
        colorDownloadQueue.maxConcurrentOperationCount = 5
    }

    class func podcastHasBackgroundColor(_ podcast: Podcast) -> Bool {
        ColorManager.sharedManager.podcastHasBackgroundColor(podcast)
    }

    class func backgroundColorForPodcast(_ podcast: Podcast) -> UIColor {
        ColorManager.sharedManager.backgroundColorForPodcast(podcast)
    }

    class func backgroundColorForPodcastUuid(_ uuid: String) -> UIColor {
        guard let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) else {
            return ColorManager.sharedManager.defaultBackgroundColor
        }
        return ColorManager.sharedManager.backgroundColorForPodcast(podcast)
    }

    class func darkThemeTintColorForPodcastUuid(_ uuid: String, completion: @escaping ((UIColor) -> Void)) {
        CacheServerHandler.shared.loadPodcastColors(podcastUuid: uuid, allowCachedVersion: true, completion: { _, _, darkThemeTint in
            guard let darkThemeTint else {
                completion(ColorManager.sharedManager.defaultDarkTintColor)

                return
            }

            completion(UIColor(hex: darkThemeTint))
        })
    }

    class func lightThemeTintForPodcast(_ podcast: Podcast, defaultColor: UIColor? = nil) -> UIColor {
        ColorManager.sharedManager.lightThemeTintForPodcast(podcast, defaultColor: defaultColor)
    }

    class func darkThemeTintForPodcast(_ podcast: Podcast, defaultColor: UIColor? = nil) -> UIColor {
        ColorManager.sharedManager.darkThemeTintForPodcast(podcast, defaultColor: defaultColor)
    }

    private func podcastHasBackgroundColor(_ podcast: Podcast) -> Bool {
        podcast.backgroundColor != nil && podcast.colorVersion == currentColorVersion
    }

    func updateColorsIfRequired(_ podcast: Podcast) {
        if podcast.colorVersion < currentColorVersion {
            scheduleColorDownload(podcast)
        }
    }

    private func backgroundColorForPodcast(_ podcast: Podcast) -> UIColor {
        if let colorStr = podcast.backgroundColor, podcast.colorVersion == currentColorVersion {
            return UIColor(hex: colorStr)
        }

        updateColorsIfRequired(podcast)

        return defaultBackgroundColor
    }

    private func lightThemeTintForPodcast(_ podcast: Podcast, defaultColor: UIColor? = nil) -> UIColor {
        if let colorStr = podcast.primaryColor, podcast.colorVersion == currentColorVersion {
            if colorStr == defaultServerLightTint {
                return defaultColor ?? defaultLightTintColor
            }

            return UIColor(hex: colorStr)
        }

        updateColorsIfRequired(podcast)

        return defaultColor ?? defaultLightTintColor
    }

    private func darkThemeTintForPodcast(_ podcast: Podcast, defaultColor: UIColor? = nil) -> UIColor {
        if let colorStr = podcast.secondaryColor, podcast.colorVersion == currentColorVersion {
            if colorStr == defaultServerDarkTint {
                return defaultColor ?? defaultDarkTintColor
            }

            return UIColor(hex: colorStr)
        }

        updateColorsIfRequired(podcast)

        return defaultColor ?? defaultDarkTintColor
    }

    private func removeDownloadingUuid(_ podcastUuid: String) {
        objc_sync_enter(lock)

        if let removeIndex = downloadingPodcasts.firstIndex(of: podcastUuid) {
            downloadingPodcasts.remove(at: removeIndex)
        }

        objc_sync_exit(lock)
    }

    private func addDownloadingUuid(_ podcastUuid: String) -> Bool {
        objc_sync_enter(lock)
        defer { objc_sync_exit(lock) }

        if downloadingPodcasts.contains(podcastUuid) {
            return false
        }

        downloadingPodcasts.append(podcastUuid)

        return true
    }

    private func scheduleColorDownload(_ podcast: Podcast) {
        if !addDownloadingUuid(podcast.uuid) { return }

        // make sure we don't re-download in a short period of time
        if podcast.lastColorDownloadDate != nil, abs(podcast.lastColorDownloadDate!.timeIntervalSinceNow) < minTimeBetweenColorRefreshAttempts {
            removeDownloadingUuid(podcast.uuid)

            return // not enough time since we last tried to load colors for this podcast
        }

        let podcastUuid = podcast.uuid
        colorDownloadQueue.addOperation { [weak self] in
            guard let strongSelf = self else { return }

            // we set this up so that we can wait for the async request to finish before returning out of thread
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()

            PodHopperArtworkColor.loadColors(forPodcastUuid: podcastUuid, completion: { backgroundColor, lightThemeTint, darkThemeTint in
                guard let backgroundColor, let lightThemeTint, let darkThemeTint else {
                    strongSelf.handleDownloadError(podcastUuid: podcastUuid)
                    dispatchGroup.leave()

                    return
                }

                if let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true) {
                    podcast.backgroundColor = backgroundColor
                    podcast.primaryColor = lightThemeTint
                    podcast.secondaryColor = darkThemeTint
                    podcast.colorVersion = strongSelf.currentColorVersion
                    podcast.lastColorDownloadDate = Date()
                    DataManager.sharedManager.save(podcast: podcast)

                    strongSelf.colorsDidSave(podcastUuid: podcastUuid)
                }
                dispatchGroup.leave()
            })

            dispatchGroup.wait()
        }
    }

    private func colorsDidSave(podcastUuid: String) {
        removeDownloadingUuid(podcastUuid)

        NotificationCenter.postOnMainThread(notification: Constants.Notifications.podcastColorsDownloaded, object: podcastUuid)
    }

    private func handleDownloadError(podcastUuid: String) {
        if let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true) {
            podcast.lastColorDownloadDate = Date()
            DataManager.sharedManager.save(podcast: podcast)
        }

        removeDownloadingUuid(podcastUuid)
    }
}

/// PodHopper computes podcast tint colors on-device from the feed artwork instead of fetching them
/// from the Pocket Casts metadata server, which has no entry for feed podcasts. It produces the same
/// three values ColorManager expects: a background color, a tint that reads on light backgrounds, and
/// a tint that reads on dark backgrounds. This mirrors the intent of the Android color analysis,
/// which derives a podcast's color from its artwork rather than a remote service.
///
/// This lives in ColorManager.swift on purpose: it is the sole caller, and keeping it in an
/// already-compiled file avoids any dependency on a new file being picked up by the project.
enum PodHopperArtworkColor {

    /// Downloads a podcast's artwork and derives (background, lightBgTint, darkBgTint) as hex strings.
    /// Calls completion with (nil, nil, nil) on any failure, exactly matching the shape of the server
    /// call it replaces, so the caller needs no other changes. The completion runs on a background
    /// thread, the same as the previous network completion.
    static func loadColors(forPodcastUuid uuid: String, completion: @escaping ((String?, String?, String?) -> Void)) {
        let url = artworkURL(forPodcast: uuid)

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data), let colors = deriveColors(from: image) else {
                completion(nil, nil, nil)
                return
            }

            completion(colors.background, colors.lightTint, colors.darkTint)
        }.resume()
    }

    /// Resolve a podcast's artwork URL the same way the main image path does: the feed's own artwork
    /// when present, falling back to the Pocket Casts image server only when a podcast has none. This
    /// resolver is duplicated here on purpose, because ColorManager also compiles into the Watch app
    /// target, where the app side image helper does not exist but DataManager and ServerHelper do.
    private static func artworkURL(forPodcast uuid: String) -> URL {
        if let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true),
           let feedArtwork = podcast.imageURL,
           !feedArtwork.isEmpty,
           let feedArtworkUrl = URL(string: feedArtwork) {
            return feedArtworkUrl
        }

        return ServerHelper.imageUrl(podcastUuid: uuid, size: 280)
    }

    /// Turns a representative artwork color into the three stored colors. Saturation is only injected
    /// when the artwork actually has color, so greyscale artwork yields neutral (untinted) results
    /// rather than picking up an arbitrary hue.
    private static func deriveColors(from image: UIImage) -> (background: String, lightTint: String, darkTint: String)? {
        guard let base = representativeColor(from: image) else { return nil }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let isGrey = saturation < 0.12

        // Background: keep the artwork hue, clamp brightness into a mid band so overlaid content reads.
        let background = UIColor(hue: hue,
                                 saturation: isGrey ? 0 : max(saturation, 0.30),
                                 brightness: min(max(brightness, 0.30), 0.72),
                                 alpha: 1)

        // Tint for light backgrounds: darker and saturated so it reads against white.
        let lightTint = UIColor(hue: hue,
                                saturation: isGrey ? 0 : max(saturation, 0.55),
                                brightness: min(max(brightness, 0.30), 0.50),
                                alpha: 1)

        // Tint for dark backgrounds: lighter and moderately saturated so it reads against near-black.
        let darkTint = UIColor(hue: hue,
                               saturation: isGrey ? 0 : min(max(saturation, 0.45), 0.75),
                               brightness: max(brightness, 0.82),
                               alpha: 1)

        return (background.hexString(), lightTint.hexString(), darkTint.hexString())
    }

    /// Picks a vibrant dominant color from the artwork by histogramming a downsampled copy. Pixels are
    /// quantized into coarse hue/saturation/brightness buckets; the most populous bucket wins and its
    /// averaged color is returned. Saturated, mid-bright pixels are preferred, but if the artwork has
    /// none (a greyscale or near-monochrome image) it falls back to the plain dominant color so a
    /// result is always produced when there is any opaque pixel.
    private static func representativeColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let dimension = 48
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * dimension
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * bytesPerPixel)

        guard let context = CGContext(data: &pixels,
                                      width: dimension,
                                      height: dimension,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        var vibrant = [Int: PodHopperColorBucket]()
        var overall = [Int: PodHopperColorBucket]()

        var index = 0
        while index < pixels.count {
            let r = Double(pixels[index]) / 255.0
            let g = Double(pixels[index + 1]) / 255.0
            let b = Double(pixels[index + 2]) / 255.0
            let a = Double(pixels[index + 3]) / 255.0
            index += bytesPerPixel

            if a < 0.5 { continue }

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            let key = (Int(hue * 17.0) << 6) | (Int(saturation * 7.0) << 3) | Int(brightness * 7.0)

            overall[key, default: PodHopperColorBucket()].add(r: r, g: g, b: b)

            if brightness >= 0.15, brightness <= 0.95, saturation >= 0.35 {
                vibrant[key, default: PodHopperColorBucket()].add(r: r, g: g, b: b)
            }
        }

        let chosen = vibrant.isEmpty ? overall : vibrant
        guard let winner = chosen.values.max(by: { $0.count < $1.count }) else {
            return nil
        }

        return UIColor(red: CGFloat(winner.r / Double(winner.count)),
                       green: CGFloat(winner.g / Double(winner.count)),
                       blue: CGFloat(winner.b / Double(winner.count)),
                       alpha: 1)
    }
}

/// Accumulates a count and summed rgb for a quantized color bucket so the winning bucket can be
/// averaged back into a smooth representative color.
private struct PodHopperColorBucket {
    var count = 0
    var r = 0.0
    var g = 0.0
    var b = 0.0

    mutating func add(r: Double, g: Double, b: Double) {
        count += 1
        self.r += r
        self.g += g
        self.b += b
    }
}
