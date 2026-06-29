import Foundation
import PocketCastsDataModel
import PocketCastsUtils
#if os(watchOS)
    import WatchKit
#else
    import UIKit
#endif

protocol BaseRequest: Encodable {
    var device: String? { get set }
    var m: String? { get set }
    var av: String? { get set }
    var l: String? { get set }
    var c: String? { get set }
    var dt: String? { get set }
    var v: String? { get set }
}

public class MainServerHandler {
    private static let callTimeout = 60.seconds

    public static let shared = MainServerHandler()

    private static let parserVersion = "1.7"
    private static let deviceType = "1"

    private lazy var securityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"

        return formatter
    }()

    private lazy var searchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    private let tokenHelper = TokenHelper.shared

    struct PodcastSearchQuery: BaseRequest {
        var q: String?
        var dt: String?
        var device: String?
        var v: String?
        var m: String?
        var av: String?
        var l: String?
        var c: String?
    }

    private struct PodcastUuidSearchQuery: BaseRequest {
        var id: Int?
        var dt: String?
        var device: String?
        var v: String?
        var m: String?
        var av: String?
        var l: String?
        var c: String?
    }

    private struct ShareListRequest: BaseRequest {
        var dt: String?
        var device: String?
        var v: String?
        var m: String?
        var av: String?
        var l: String?
        var c: String?
    }

    private struct ExportPodcastsRequest: BaseRequest {
        var uuids: [String]?
        var device: String?
        var m: String?
        var av: String?
        var l: String?
        var c: String?
        var dt: String?
        var v: String?
    }

    private struct UploadOpmlRequest: BaseRequest {
        var urls: [String]?
        var pollUuids: [String]?
        var device: String?
        var m: String?
        var av: String?
        var l: String?
        var c: String?
        var dt: String?
        var v: String?

        public enum CodingKeys: String, CodingKey {
            case urls, pollUuids = "poll_uuids", device, m, av, l, c, dt, v
        }
    }

    public func sendOpmlChunk(feedUrls: [String] = [], pollUuids: [String] = [], completion: @escaping (ImportOpmlResponse?) -> Void) {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            completion(ImportOpmlResponse.failedResponse())
            return
        }

        var baseRequest: BaseRequest = UploadOpmlRequest()
        addStandardParams(baseRequest: &baseRequest, uniqueId: uniqueId)

        var uploadRequest = baseRequest as! UploadOpmlRequest
        uploadRequest.urls = feedUrls
        uploadRequest.pollUuids = pollUuids

        let url = ServerHelper.asUrl(ServerConstants.Urls.main() + "import/opml")
        guard let request = ServerHelper.createJsonRequest(url: url, params: uploadRequest, timeout: MainServerHandler.callTimeout, cachePolicy: .reloadIgnoringCacheData) else {
            completion(ImportOpmlResponse.failedResponse())
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                completion(ImportOpmlResponse.failedResponse())
                return
            }

            do {
                let refreshResponse = try JSONDecoder().decode(ImportOpmlResponse.self, from: data)
                completion(refreshResponse)
            } catch {
                completion(ImportOpmlResponse.failedResponse())
            }
        }.resume()
    }

    public func exportPodcasts(uuids: [String], completion: @escaping (ExportPodcastsResponse?) -> Void) {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            completion(ExportPodcastsResponse.failedResponse())
            return
        }

        var baseRequest: BaseRequest = ExportPodcastsRequest()
        addStandardParams(baseRequest: &baseRequest, uniqueId: uniqueId)

        var exportRequest = baseRequest as! ExportPodcastsRequest
        exportRequest.uuids = uuids

        let url = ServerHelper.asUrl(ServerConstants.Urls.main() + "import/export_feed_urls")
        guard let request = ServerHelper.createJsonRequest(url: url, params: exportRequest, timeout: MainServerHandler.callTimeout, cachePolicy: .reloadIgnoringCacheData) else {
            completion(ExportPodcastsResponse.failedResponse())
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                completion(ExportPodcastsResponse.failedResponse())
                return
            }

            do {
                let refreshResponse = try JSONDecoder().decode(ExportPodcastsResponse.self, from: data)
                completion(refreshResponse)
            } catch {
                completion(ExportPodcastsResponse.failedResponse())
            }
        }.resume()
    }

    public func lookupShareLink(sharePath: String, completion: @escaping (ShareListResponse?) -> Void) {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            completion(ShareListResponse.failedResponse())
            return
        }

        var shareLinkRequest: BaseRequest = ShareListRequest()
        addStandardParams(baseRequest: &shareLinkRequest, uniqueId: uniqueId)

        let url = ServerHelper.asUrl(ServerConstants.Urls.main() + sharePath)
        guard let request = ServerHelper.createJsonRequest(url: url, params: shareLinkRequest as! ShareListRequest, timeout: MainServerHandler.callTimeout, cachePolicy: .reloadIgnoringCacheData) else {
            completion(ShareListResponse.failedResponse())
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                completion(ShareListResponse.failedResponse())
                return
            }

            do {
                let refreshResponse = try JSONDecoder().decode(ShareListResponse.self, from: data)
                completion(refreshResponse)
            } catch {
                completion(ShareListResponse.failedResponse())
            }
        }.resume()
    }

    public func refresh(podcasts: [Podcast], completion: @escaping (PodcastRefreshResponse?) -> Void) {
        // PodHopper refreshes by re-fetching each podcast's RSS feed on device rather than asking the
        // Pocket Casts refresh server, which does not know PodHopper's feed derived podcast uuids. The
        // response shape is identical, so everything downstream (RefreshOperation, which dedups by
        // episode uuid and inserts only new episodes) is unchanged. Runs off the calling thread so this
        // method stays non blocking, the same as the previous network call.
        FileLog.shared.addMessage("Refresh - Started (on-device feeds)")

        DispatchQueue.global(qos: .utility).async {
            let response = PodHopperRefresh.refreshResponse(for: podcasts)
            let updatedCount = response.result?.podcastUpdates?.count ?? 0
            FileLog.shared.addMessage("Refresh - Parsed feeds, \(updatedCount) podcast(s) returned episodes")
            completion(response)
        }
    }

    public func createRefreshRequest(podcasts: [Podcast]) -> URLRequest? {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            return nil
        }

        for podcast in podcasts { // ensure podcasts have up to date latest episode uuids
            ServerPodcastManager.shared.updateLatestEpisodeInfo(podcast: podcast, setDefaults: false)
        }

        let pushEnabled = ServerConfig.shared.syncDelegate?.isPushEnabled() ?? false

        var jsonRequest = jsonWithStandardParams(uniqueId: uniqueId)
        jsonRequest["push_sound"] = "11" // for legacy reasons, this is always the push sound we send, since it's no longer configurable
        jsonRequest["podcasts"] = podcasts.map(\.uuid).joined(separator: ",")
        jsonRequest["last_episodes"] = podcasts.map { $0.forceRefreshEpisodeFrom ?? $0.latestEpisodeUuid ?? "" }.joined(separator: ",")
        jsonRequest["push_messages_on"] = podcasts.map { (pushEnabled && $0.isPushEnabled) ? "1" : "0" }.joined()
        if let pushToken = ServerSettings.pushToken() {
            jsonRequest["push_token"] = pushToken
        }
        jsonRequest["push_on"] = pushEnabled ? "true" : "false"
        guard let data = try? JSONSerialization.data(withJSONObject: jsonRequest) else {
            FileLog.shared.addMessage("Failed to create refresh request")
            return nil
        }

        let url = ServerHelper.asUrl(ServerConstants.Urls.main() + "user/update")
        let request = ServerHelper.createJsonRequest(url: url, data: data, timeout: MainServerHandler.callTimeout, cachePolicy: .reloadIgnoringCacheData)

        return request
    }

    public func podcastSearch(searchTerm: String, completion: @escaping (PodcastSearchResponse?) -> Void) {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            completion(PodcastSearchResponse.failedResponse())
            return
        }

        var baseQuery: BaseRequest = PodcastSearchQuery()
        addStandardParams(baseRequest: &baseQuery, uniqueId: uniqueId)

        var searchQuery = baseQuery as! PodcastSearchQuery
        searchQuery.q = searchTerm

        let searchOperation = PodcastSearchOperation(searchQuery: searchQuery, completionHandler: completion)
        searchQueue.addOperation(searchOperation)
    }

    func podcastSearchQuery(searchTerm: String) -> PodcastSearchQuery? {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            return nil
        }

        var baseQuery: BaseRequest = PodcastSearchQuery()
        addStandardParams(baseRequest: &baseQuery, uniqueId: uniqueId)

        var searchQuery = baseQuery as! PodcastSearchQuery
        searchQuery.q = searchTerm

        return searchQuery
    }

    public func refreshPodcastFeed(podcast: Podcast, completion: @escaping (Bool) -> Void) {
        // PodHopper re-fetches and re-parses the feed on device instead of asking the Pocket Casts
        // server to refresh it, which has no record of feed derived podcasts. Any episodes the feed
        // contains that are not already stored are inserted (dedup by episode uuid). Reports success
        // when the feed could be fetched and parsed.
        guard let feedUrl = podcast.podcastUrl, !feedUrl.isEmpty else {
            completion(false)

            return
        }

        FileLog.shared.addMessage("Attempting on-device feed refresh for \(podcast.uuid)")
        DispatchQueue.global(qos: .utility).async {
            guard let parsed = PodHopperFeedParser().parse(feedUrl: feedUrl) else {
                FileLog.shared.addMessage("Feed refresh failed: could not fetch or parse feed for \(podcast.uuid)")
                completion(false)

                return
            }

            let newEpisodes = parsed.episodes.filter { DataManager.sharedManager.findEpisode(uuid: $0.uuid) == nil }
            for episode in newEpisodes {
                episode.podcast_id = podcast.id
                episode.podcastUuid = podcast.uuid
            }

            if !newEpisodes.isEmpty {
                DataManager.sharedManager.bulkSave(episodes: newEpisodes)
                ServerPodcastManager.shared.updateLatestEpisodeInfo(podcast: podcast, setDefaults: false)
            }

            FileLog.shared.addMessage("On-device feed refresh complete for \(podcast.uuid), added \(newEpisodes.count) episode(s)")
            completion(true)
        }
    }

    public func findPodcastByiTunesId(_ iTunesId: Int, completion: @escaping (String?) -> Void) {
        guard let uniqueId = ServerConfig.shared.syncDelegate?.uniqueAppId() else {
            completion(nil)
            return
        }

        var baseQuery: BaseRequest = PodcastUuidSearchQuery()
        addStandardParams(baseRequest: &baseQuery, uniqueId: uniqueId)

        var searchQuery = baseQuery as! PodcastUuidSearchQuery
        searchQuery.id = iTunesId

        let url = ServerHelper.asUrl(ServerConstants.Urls.main() + "podcasts/show")
        guard let request = ServerHelper.createJsonRequest(url: url, params: searchQuery, timeout: MainServerHandler.callTimeout, cachePolicy: .useProtocolCachePolicy) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                completion(nil)
                return
            }

            do {
                let searchResponse = try JSONDecoder().decode(PodcastSearchResponse.self, from: data)
                completion(searchResponse.result?.podcast?.uuid)
            } catch {
                completion(nil)
            }
        }.resume()
    }

    public func updatePodcast(uuid: String, lastEpisodeUuid: String?) async throws -> Bool {
        // PodHopper checks for new episodes by parsing the podcast's feed on device rather than asking
        // the Pocket Casts update endpoint, which does not know PodHopper's feed derived podcast uuids.
        // Returns whether the feed contains an episode that is not already stored locally. The caller
        // then runs the normal on-device refresh to insert them, which dedups by episode uuid.
        guard
            let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true),
            let feedUrl = podcast.podcastUrl,
            !feedUrl.isEmpty
        else {
            return false
        }

        if Task.isCancelled {
            return false
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let parsed = PodHopperFeedParser().parse(feedUrl: feedUrl) else {
                    continuation.resume(returning: false)
                    return
                }

                let hasNewEpisode = parsed.episodes.contains { DataManager.sharedManager.findEpisode(uuid: $0.uuid) == nil }
                continuation.resume(returning: hasNewEpisode)
            }
        }
    }

    private func jsonWithStandardParams(uniqueId: String) -> [String: Any] {
        var json: [String: Any] = [:]
        let locale = Locale.current
        json["l"] = locale.language.languageCode?.identifier
        json["c"] = locale.region?.identifier

        #if os(watchOS)
            json["m"] = WKInterfaceDevice.current().systemVersion
        #else
            json["m"] = UIDevice.current.systemVersion
        #endif

        json["dt"] = MainServerHandler.deviceType
        json["v"] = MainServerHandler.parserVersion
        json["device"] = uniqueId
        json["av"] = ServerConfig.shared.syncDelegate?.appVersion()

        return json
    }

    private func addStandardParams(baseRequest: inout BaseRequest, uniqueId: String) {
        let locale = Locale.current
        baseRequest.l = locale.language.languageCode?.identifier
        baseRequest.c = locale.region?.identifier

        #if os(watchOS)
            baseRequest.m = WKInterfaceDevice.current().systemVersion
        #else
            baseRequest.m = UIDevice.current.systemVersion
        #endif

        baseRequest.dt = MainServerHandler.deviceType
        baseRequest.v = MainServerHandler.parserVersion
        baseRequest.device = uniqueId
        baseRequest.av = ServerConfig.shared.syncDelegate?.appVersion()
    }
}
