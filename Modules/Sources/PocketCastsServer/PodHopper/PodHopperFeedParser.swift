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
    /// "HTTP 403" or an error summary) so the caller can show what went wrong.
    public enum FeedResult {
        case success(ParsedFeed)
        case failure(reason: String)
    }

    public init() {}

    // MARK: Deterministic ids

    /// Deterministic podcast id derived from the feed URL.
    public func podcastUuid(forFeed feedUrl: String) -> String {
        PodHopperUUID.podcastUuid(forFeed: feedUrl)
    }

    // MARK: Network fetch then parse

    private static let userAgent = "PodHopper/1.0"
    private static let accept = "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5"

    /// Download and parse the feed at `feedUrl`. Runs blocking, so call it off the main thread.
    public func fetch(feedUrl: String) -> FeedResult {
        let trimmed = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return .failure(reason: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        var data: Data?
        var failureReason: String?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { responseData, response, error in
            if let error = error {
                failureReason = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failureReason = "HTTP \(http.statusCode)"
            } else {
                data = responseData
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let reason = failureReason {
            return .failure(reason: reason)
        }
        guard let data = data else {
            return .failure(reason: "Empty response")
        }
        guard let parsed = parse(data: data, feedUrl: trimmed) else {
            return .failure(reason: "Feed format not recognized")
        }
        return .success(parsed)
    }

    /// Convenience wrapper returning nil on any failure.
    public func parse(feedUrl: String) -> ParsedFeed? {
        if case let .success(feed) = fetch(feedUrl: feedUrl) { return feed }
        return nil
    }

    // MARK: Pure parse (no network, unit testable)

    /// Parse already downloaded feed bytes. FeedKit first, lenient `XMLParser` fallback.
    public func parse(data: Data, feedUrl: String) -> ParsedFeed? {
        if let rss = try? RSSFeed(data: data), let built = buildFromStrict(rss, feedUrl: feedUrl) {
            return built
        }
        return parseLeniently(data: data, feedUrl: feedUrl)
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
    func parseLeniently(data: Data, feedUrl: String) -> ParsedFeed? {
        let url = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let podcastUuid = PodHopperUUID.podcastUuid(forFeed: url)

        let delegate = LenientFeedDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }

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
            let guid = raw.guid.isEmpty ? audioUrl : raw.guid
            return makeEpisode(
                uuid: PodHopperUUID.episodeUuid(forGuid: guid),
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
                if !current.enclosureUrl.isEmpty {
                    items.append(current)
                }
                inItem = false
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
