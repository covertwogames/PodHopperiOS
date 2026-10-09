import Foundation
import PocketCastsUtils
#if canImport(UIKit)
import UIKit
#endif

public class ServerHelper: NSObject {
    // MARK: Url Helpers

    public static func asUrl(_ url: String) -> URL {
        URL(string: url)!
    }

    public static func image(podcastUuid: String, size: Int) -> String {
        "\(ServerConstants.Urls.discover())images/\(size)/\(podcastUuid).jpg"
    }

    /// PodHopper: there is no artwork server. A podcast's artwork comes from its own feed, and this is
    /// only used for a podcast whose feed has none. It returns a file location that never exists, so
    /// the image load fails straight away and the caller shows its usual placeholder, without
    /// contacting any server.
    public static func imageUrl(podcastUuid: String, size: Int) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PodHopperNoArtwork", isDirectory: true)
            .appendingPathComponent("\(podcastUuid)-\(size).jpg")
    }

    /// PodHopper: the colored artwork for your own files is drawn on the device instead of being
    /// downloaded. Each color is a plain tile in the same color the app uses for that file elsewhere
    /// (AppTheme.userEpisodeColor, light and dark), drawn once and then kept in the caches folder.
    public static func userEpisodeDefaultImageUrl(isDark: Bool, color: Int, size: Int) -> URL {
        let palette = isDark ? userEpisodeDarkColors : userEpisodeLightColors
        let hex = palette[color] ?? userEpisodeNoArtworkColor
        let side = min(max(size, 1), 960)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("PodHopperFileArtwork", isDirectory: true)
        let fileURL = folder.appendingPathComponent("\(isDark ? "dark" : "light")-\(color)-\(side).png")

        if !FileManager.default.fileExists(atPath: fileURL.path), let data = solidColorPNG(hex: hex, side: side) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }

        return fileURL
    }

    /// The grey used for a file with no color chosen (AppTheme.userEpisodeNoArtworkColor).
    private static let userEpisodeNoArtworkColor: UInt32 = 0x8F97A4

    /// File colors 1 to 8 as the light themes draw them (grey, red, blue, green, yellow, orange, purple, pink).
    private static let userEpisodeLightColors: [Int: UInt32] = [
        1: 0x8F97A4, 2: 0xF43E37, 3: 0x03A9F4, 4: 0x78D549, 5: 0xFEC635, 6: 0xFF9D3B, 7: 0x5D31C4, 8: 0xE93673
    ]

    /// File colors 1 to 8 as the dark themes draw them.
    private static let userEpisodeDarkColors: [Int: UInt32] = [
        1: 0x8F97A4, 2: 0xDF514C, 3: 0x1BA0DC, 4: 0x7FBF5F, 5: 0xEABD49, 6: 0xEB9D4F, 7: 0x9D79F2, 8: 0xD24D7A
    ]

    private static func solidColorPNG(hex: UInt32, side: Int) -> Data? {
        #if canImport(UIKit)
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        guard let image = context.makeImage() else { return nil }

        return UIImage(cgImage: image).pngData()
        #else
        return nil
        #endif
    }

    public static func colorUrl(podcastUuid: String) -> URL {
        URL(string: "\(ServerConstants.Urls.discover())images/metadata/\(podcastUuid).json")!
    }

    public static func playerUrl(podcastUuid: String, episodeUuid: String, playedUpTo: Double) -> URL {
        let urlString = NSString(format: "https://play.pocketcasts.com/web/user/handoff?podcast=%@&episode=%@&t=%1.0lf", podcastUuid, episodeUuid, round(playedUpTo))

        return URL(string: urlString as String)!
    }

    public static func bundleUrl(bundleUuid: String) -> URL {
        URL(string: "\(ServerConstants.Urls.lists())bundle-\(bundleUuid).json")!
    }

    class func decodeRefreshResponse(from data: Data) -> PodcastRefreshResponse {
        do {
            let jsonDecoder = JSONDecoder()
            jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
            return try jsonDecoder.decode(PodcastRefreshResponse.self, from: data)
        } catch {
            FileLog.shared.addMessage("Unable to decode refresh response \(error.localizedDescription)")
            return PodcastRefreshResponse.failedResponse()
        }
    }

    class func createJsonRequest(url: URL, data: Data, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: ServerConstants.HttpHeaders.accept)
        request.setValue("application/json; charset=UTF8", forHTTPHeaderField: ServerConstants.HttpHeaders.contentType)
        request.setValue(ServerConfig.shared.syncDelegate?.privateUserAgent(), forHTTPHeaderField: ServerConstants.HttpHeaders.userAgent)
        request.addLocalizationHeaders()
        request.httpBody = data

        return request
    }

    class func createJsonRequest<T: Encodable>(url: URL, params: T, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy) -> URLRequest? {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: ServerConstants.HttpHeaders.accept)
        request.setValue("application/json; charset=UTF8", forHTTPHeaderField: ServerConstants.HttpHeaders.contentType)
        request.setValue(ServerConfig.shared.syncDelegate?.privateUserAgent(), forHTTPHeaderField: ServerConstants.HttpHeaders.userAgent)
        request.addLocalizationHeaders()

        do {
            let dataToSend = try JSONEncoder().encode(params)
            request.httpBody = dataToSend
        } catch {
            FileLog.shared.addMessage("Encoding JSON request failed \(error.localizedDescription)")
            return nil
        }

        return request
    }

    class func createProtoRequest(url: URL, data: Data) -> URLRequest? {
        var request = createEmptyProtoRequest(url: url)
        request?.httpBody = data

        return request
    }

    class func createEmptyProtoRequest(url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy, timeoutInterval: TimeInterval = 15.seconds) -> URLRequest? {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.addValue("application/octet-stream", forHTTPHeaderField: ServerConstants.HttpHeaders.accept)
        request.setValue("application/octet-stream", forHTTPHeaderField: ServerConstants.HttpHeaders.contentType)
        request.setValue(ServerConfig.shared.syncDelegate?.privateUserAgent(), forHTTPHeaderField: ServerConstants.HttpHeaders.userAgent)
        request.addLocalizationHeaders()

        return request
    }
}
