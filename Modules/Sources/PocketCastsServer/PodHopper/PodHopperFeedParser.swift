import FeedKit
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// PodHopper's client side RSS feed engine (parsing half).
///
/// Fetches a podcast's RSS feed directly over the network (no Pocket Casts server involved) and
/// maps it into the same `Podcast` and `Episode` objects the rest of the app already lists and
/// plays. Persistence is handled separately by `PodHopperFeedManager`; this type only turns feed
/// bytes into model objects.
///
/// Parsing runs in two passes, mirroring the Android client. The strict library parser (FeedKit)
/// runs first because it is well tested for spec correct feeds. When it cannot parse a feed (some
/// real world hosts omit elements or wrap things in ways a strict parser rejects), a lenient
/// `XMLParser` pass takes over and extracts whatever recognizable fields are present.
///
/// Ids are derived deterministically through `PodHopperUUID`: the podcast id comes from the feed
/// URL and each episode id from its RSS guid (falling back to the audio enclosure URL). That makes
/// the same feed always produce the same podcast id and the same episode always produce the same
/// episode id, which keeps the local database stable across refreshes and matches the ids the
/// Android app and the car derive, so Supabase sync lines up across platforms.
public final class PodHopperFeedParser {

    public struct ParsedFeed {
        public let podcast: PocketCastsDataModel.Podcast
        public let episodes: [PocketCastsDataModel.Episode]
    }

    /// Outcome of a feed fetch. `failure` carries a short human readable cause (an HTTP status like
    /// "HTTP 403" or an error summary) so the caller can show what went wrong. `notModified` is only
    /// ever returned for a conditional fetch, and means the host confirmed the feed is unchanged, so
    /// there is nothing to parse and nothing to save.
    public enum FeedResult {
        case success(ParsedFeed, validators: PodHopperFeedValidators.Validators?)
        case notModified
        case failure(reason: String)
    }

    public init() {}

    // MARK: Deterministic ids

    /// Deterministic podcast id derived from the feed URL.
    public func podcastUuid(forFeed feedUrl: String) -> String {
        PodHopperUUID.podcastUuid(forFeed: feedUrl)
    }

    // MARK: Network fetch then parse

    /// PodHopper: how many of the newest episodes the watch keeps per podcast. Matches Android's
    /// watch cap. Older episodes are fetched one at a time when sync needs them.
    public static let watchEpisodeCap = 25

    private static let userAgent = "PodHopper/1.0"
    private static let accept = "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5"

    /// Download and parse the feed at `feedUrl`. Runs blocking, so call it off the main thread.
    ///
    /// PodHopper: pass `conditional: true` from refresh paths. The request then carries whatever the
    /// host last told us about this feed, and a host that answers "not modified" costs us no body to
    /// download, no parse and no database work. Paths that need the episodes themselves (subscribing,
    /// filling a stub podcast) must leave it false, because "not modified" returns no feed at all.
    ///
    /// The system URL cache is bypassed for feed requests so the conditional headers we send are the
    /// ones the host answers, rather than the session quietly serving its own cached copy.
    public func fetch(feedUrl: String, conditional: Bool = false, maxEpisodes: Int? = nil, stopAtEpisodeUuid: String? = nil) -> FeedResult {
        let trimmed = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return .failure(reason: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if conditional, let known = PodHopperFeedValidators.shared.stored(for: trimmed) {
            if let etag = known.etag, !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = known.lastModified, !lastModified.isEmpty {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        var data: Data?
        var failureReason: String?
        var notModified = false
        var validators: PodHopperFeedValidators.Validators?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { responseData, response, error in
            if let error = error {
                failureReason = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode == 304 {
                notModified = true
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failureReason = "HTTP \(http.statusCode)"
            } else {
                data = responseData
                if let http = response as? HTTPURLResponse {
                    let etag = http.value(forHTTPHeaderField: "ETag")
                    let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                    let found = PodHopperFeedValidators.Validators(etag: etag, lastModified: lastModified)
                    validators = found
                }
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if notModified {
            return .notModified
        }
        if let reason = failureReason {
            return .failure(reason: reason)
        }
        guard let data = data else {
            return .failure(reason: "Empty response")
        }
        guard let parsed = parse(data: data, feedUrl: trimmed, maxEpisodes: maxEpisodes, stopAtEpisodeUuid: stopAtEpisodeUuid) else {
            return .failure(reason: "Feed format not recognized")
        }
        return .success(parsed, validators: validators)
    }

    /// Convenience wrapper returning nil on any failure. Always fetches in full: callers that want
    /// the "has this changed?" behaviour use `fetch(feedUrl:conditional:)` and handle `notModified`.
    public func parse(feedUrl: String, maxEpisodes: Int? = nil) -> ParsedFeed? {
        if case let .success(feed, _) = fetch(feedUrl: feedUrl, maxEpisodes: maxEpisodes) { return feed }
        return nil
    }

    /// Fetch a feed and read it only as far as one particular episode, used when sync names an
    /// episode this device does not hold. Returns nil if the feed does not contain it.
    public func parse(feedUrl: String, containingEpisodeUuid episodeUuid: String) -> ParsedFeed? {
        guard case let .success(feed, _) = fetch(feedUrl: feedUrl, stopAtEpisodeUuid: episodeUuid) else { return nil }
        return feed.episodes.contains(where: { $0.uuid == episodeUuid }) ? feed : nil
    }

    // MARK: Pure parse (no network, unit testable)

    /// Parse already downloaded feed bytes. FeedKit first, lenient `XMLParser` fallback.
    ///
    /// PodHopper: pass `maxEpisodes` to stop after that many episodes, or `stopAtEpisodeUuid` to
    /// stop once a particular episode has been read. Either one skips the FeedKit path, because
    /// FeedKit builds the whole feed in one go and cannot be stopped part way. The watch uses the
    /// limit so a feed with thousands of episodes costs it 25 episode objects instead of thousands.
    public func parse(data: Data, feedUrl: String, maxEpisodes: Int? = nil, stopAtEpisodeUuid: String? = nil) -> ParsedFeed? {
        if maxEpisodes == nil, stopAtEpisodeUuid == nil {
            if let rss = try? RSSFeed(data: data), let built = buildFromStrict(rss, feedUrl: feedUrl) {
                return built
            }
        }
        return parseLeniently(data: data, feedUrl: feedUrl, maxEpisodes: maxEpisodes, stopAtEpisodeUuid: stopAtEpisodeUuid)
    }

    // MARK: Strict (FeedKit) builder

    private func buildFromStrict(_ feed: RSSFeed, feedUrl: String) -> ParsedFeed? {
        guard let channel = feed.channel else { return nil }
        let url = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let podcastUuid = PodHopperUUID.podcastUuid(forFeed: url)
        let artwork = channel.iTunes?.image?.attributes?.href ?? channel.image?.url

        let podcast = makePodcast(
            uuid: podcastUuid,
            title: channel.title,
            feedUrl: url,
            description: channel.description,
            author: channel.iTunes?.author ?? "",
            imageURL: artwork
        )

        let episodes = (channel.items ?? []).compactMap { mapStrictEpisode($0, podcastUuid: podcastUuid) }
        applyLatestEpisode(to: podcast, episodes: episodes)
        return ParsedFeed(podcast: podcast, episodes: episodes)
    }

    private func mapStrictEpisode(_ item: RSSFeedItem, podcastUuid: String) -> PocketCastsDataModel.Episode? {
        guard let rawUrl = item.enclosure?.attributes?.url else { return nil }
        let audioUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !audioUrl.isEmpty else { return nil }

        let uuid = PodHopperUUID.episodeUuid(guid: item.guid?.text, enclosureUrl: audioUrl)
        let description = item.content?.encoded ?? item.description ?? ""
        return makeEpisode(
            uuid: uuid,
            podcastUuid: podcastUuid,
            title: item.title,
            description: description,
            downloadUrl: audioUrl,
            sizeInBytes: item.enclosure?.attributes?.length ?? 0,
            fileType: item.enclosure?.attributes?.type,
            duration: item.iTunes?.duration ?? 0,
            publishedDate: item.pubDate ?? Date()
        )
    }

    // MARK: Lenient (XMLParser) fallback

    /// Streams the feed and pulls out whatever recognizable fields are present, treating missing
    /// elements as simply absent rather than as a reason to reject the feed. Returns nil only when
    /// nothing usable (no channel title and no playable episodes) is found. Internal so the test
    /// suite can exercise this path directly.
    func parseLeniently(data: Data, feedUrl: String, maxEpisodes: Int? = nil, stopAtEpisodeUuid: String? = nil) -> ParsedFeed? {
        let url = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let podcastUuid = PodHopperUUID.podcastUuid(forFeed: url)

        let delegate = LenientFeedDelegate(maxItems: maxEpisodes, stopAtEpisodeUuid: stopAtEpisodeUuid)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        // Stopping early makes `parse()` report false, which is a success here: we asked it to stop.
        if !parser.parse(), !delegate.stoppedEarly { return nil }

        if (delegate.channelTitle?.isEmpty ?? true) && delegate.items.isEmpty {
            return nil
        }

        let podcast = makePodcast(
            uuid: podcastUuid,
            title: delegate.channelTitle,
            feedUrl: url,
            description: delegate.channelDescription,
            author: delegate.channelAuthor ?? "",
            imageURL: delegate.itunesImage ?? delegate.rssImageUrl
        )

        let episodes: [PocketCastsDataModel.Episode] = delegate.items.compactMap { raw in
            let audioUrl = raw.enclosureUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !audioUrl.isEmpty else { return nil }
            // PodHopper: use the same blank-guid rule as the FeedKit path. Both fall back to the
            // audio URL when the guid is missing or only whitespace, so an episode gets the same id
            // whichever parser read it. Episode ids are what Supabase sync matches across devices,
            // so the two paths disagreeing would break playback sync for that episode.
            return makeEpisode(
                uuid: PodHopperUUID.episodeUuid(guid: raw.guid, enclosureUrl: audioUrl),
                podcastUuid: podcastUuid,
                title: raw.title,
                description: raw.description,
                downloadUrl: audioUrl,
                sizeInBytes: raw.enclosureLength,
                fileType: raw.enclosureType.isEmpty ? nil : raw.enclosureType,
                duration: Self.parseDuration(raw.duration),
                publishedDate: Self.parsePubDate(raw.pubDate) ?? Date()
            )
        }

        applyLatestEpisode(to: podcast, episodes: episodes)
        return ParsedFeed(podcast: podcast, episodes: episodes)
    }

    // MARK: Model construction

    private func makePodcast(uuid: String, title: String?, feedUrl: String, description: String?, author: String, imageURL: String?) -> PocketCastsDataModel.Podcast {
        let podcast = PocketCastsDataModel.Podcast()
        podcast.uuid = uuid
        podcast.title = title
        podcast.podcastUrl = feedUrl
        podcast.podcastDescription = description
        podcast.author = author
        podcast.imageURL = imageURL
        podcast.addedDate = Date()
        podcast.subscribed = 1
        return podcast
    }

    private func makeEpisode(uuid: String, podcastUuid: String, title: String?, description: String, downloadUrl: String, sizeInBytes: Int64, fileType: String?, duration: Double, publishedDate: Date) -> PocketCastsDataModel.Episode {
        let episode = PocketCastsDataModel.Episode()
        episode.uuid = uuid
        episode.podcastUuid = podcastUuid
        episode.title = title
        episode.episodeDescription = description
        episode.downloadUrl = downloadUrl
        episode.sizeInBytes = sizeInBytes
        episode.fileType = fileType
        episode.duration = duration
        episode.publishedDate = publishedDate
        episode.addedDate = Date()
        episode.playingStatus = PlayingStatus.notPlayed.rawValue
        episode.episodeStatus = DownloadStatus.notDownloaded.rawValue
        return episode
    }

    private func applyLatestEpisode(to podcast: PocketCastsDataModel.Podcast, episodes: [PocketCastsDataModel.Episode]) {
        guard let latest = episodes.max(by: { ($0.publishedDate ?? .distantPast) < ($1.publishedDate ?? .distantPast) }) else { return }
        podcast.latestEpisodeUuid = latest.uuid
        podcast.latestEpisodeDate = latest.publishedDate
    }

    // MARK: Lenient field parsing helpers

    private static let pubDateFormats: [String] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
    ]

    static func parsePubDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in pubDateFormats {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func parseDuration(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return 0 }
            return h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return 0 }
            return m * 60 + s
        case 1:
            return Double(parts[0]) ?? 0
        default:
            return 0
        }
    }
}

// MARK: - Lenient XML delegate

/// Collects channel metadata and items from a feed without rejecting it for missing spec required
/// elements. Mirrors the Android lenient pull parser: namespaces are not processed, so element
/// names are matched on their local part (after any prefix) and prefixes like itunes and content
/// are inspected explicitly.
private final class LenientFeedDelegate: NSObject, XMLParserDelegate {

    struct RawItem {
        var title = ""
        var description = ""
        var guid = ""
        var pubDate = ""
        var duration = ""
        var enclosureUrl = ""
        var enclosureLength: Int64 = 0
        var enclosureType = ""
    }

    /// PodHopper: how many episodes to read before stopping, and an episode to stop at once seen.
    /// Both exist so a device that only needs the newest episodes, or one particular episode, does
    /// not have to build the whole feed in memory.
    private let maxItems: Int?
    private let stopAtEpisodeUuid: String?
    private(set) var stoppedEarly = false

    init(maxItems: Int? = nil, stopAtEpisodeUuid: String? = nil) {
        self.maxItems = maxItems
        self.stopAtEpisodeUuid = stopAtEpisodeUuid
        super.init()
    }

    private(set) var channelTitle: String?
    private(set) var channelDescription: String?
    private(set) var channelAuthor: String?
    private(set) var itunesImage: String?
    private(set) var rssImageUrl: String?
    private(set) var items: [RawItem] = []

    private var inItem = false
    private var inImage = false
    private var current = RawItem()
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        let local = localName(name)
        text = ""

        switch local {
        case "item":
            inItem = true
            current = RawItem()
        case "image" where !inItem:
            if let href = attribute(named: "href", in: attributes), !href.isEmpty {
                if itunesImage == nil { itunesImage = href.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                inImage = true
            }
        case "enclosure" where inItem:
            current.enclosureUrl = (attribute(named: "url", in: attributes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            current.enclosureType = (attribute(named: "type", in: attributes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            current.enclosureLength = Int64((attribute(named: "length", in: attributes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        let local = localName(name)
        let prefix = name.contains(":") ? String(name.prefix(upTo: name.firstIndex(of: ":")!)) : ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        if inItem {
            if local == "item" {
                var reachedTarget = false
                if !current.enclosureUrl.isEmpty {
                    items.append(current)
                    if let wanted = stopAtEpisodeUuid {
                        let audioUrl = current.enclosureUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        reachedTarget = PodHopperUUID.episodeUuid(guid: current.guid, enclosureUrl: audioUrl) == wanted
                    }
                }
                inItem = false

                // PodHopper: stop as soon as we have what this device asked for. abortParsing makes
                // parse() report false, so the flag records that stopping was deliberate.
                if reachedTarget || (maxItems.map { items.count >= $0 } ?? false) {
                    stoppedEarly = true
                    parser.abortParsing()
                    return
                }
            } else if local == "title" {
                if current.title.isEmpty { current.title = value }
            } else if local == "description" || (prefix == "itunes" && local == "summary") {
                if current.description.isEmpty { current.description = value }
            } else if prefix == "content" && local == "encoded" {
                if current.description.isEmpty { current.description = value }
            } else if local == "guid" {
                if current.guid.isEmpty { current.guid = value }
            } else if local == "pubdate" {
                if current.pubDate.isEmpty { current.pubDate = value }
            } else if prefix == "itunes" && local == "duration" {
                if current.duration.isEmpty { current.duration = value }
            }
        } else {
            if local == "image" {
                inImage = false
            } else if inImage && local == "url" {
                if rssImageUrl == nil { rssImageUrl = value }
            } else if !inImage && local == "title" {
                if channelTitle == nil || channelTitle?.isEmpty == true { channelTitle = value }
            } else if !inImage && (local == "description" || (prefix == "itunes" && local == "summary")) {
                if channelDescription == nil || channelDescription?.isEmpty == true { channelDescription = value }
            } else if !inImage && prefix == "itunes" && local == "author" {
                if channelAuthor == nil || channelAuthor?.isEmpty == true { channelAuthor = value }
            }
        }
    }

    private func localName(_ name: String) -> String {
        guard let range = name.range(of: ":") else { return name }
        return String(name[range.upperBound...])
    }

    private func attribute(named name: String, in attributes: [String: String]) -> String? {
        if let exact = attributes[name] { return exact }
        for (key, value) in attributes where localName(key.lowercased()) == name.lowercased() {
            return value
        }
        return nil
    }
}
