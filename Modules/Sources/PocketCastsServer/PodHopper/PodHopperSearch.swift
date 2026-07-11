import Foundation
import PocketCastsDataModel

/// PodHopper: on-device search. Podcast search is backed by the iTunes Search API and episode
/// search runs against the local database, replacing the Pocket Casts search servers. Every
/// iTunes result is stored as an idempotent unsubscribed local stub, so result uuids always
/// resolve locally and the podcast page opens without any Pocket Casts lookups.
public class PodHopperSearch {
    public static let shared = PodHopperSearch()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    struct ITunesSearchEnvelope: Decodable {
        let results: [ITunesSearchPodcast]
    }

    struct ITunesSearchPodcast: Decodable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let collectionExplicitness: String?
    }

    public func searchPodcasts(term: String, limit: Int = 30) async throws -> [PodcastFolderSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let searchURL = components?.url else {
            throw URL.URLCreationError.invalidURLString
        }

        let request = URLRequest(url: searchURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let (data, _) = try await session.data(for: request)
        let envelope = try JSONDecoder().decode(ITunesSearchEnvelope.self, from: data)

        var seen = Set<String>()
        var results = [PodcastFolderSearchResult]()
        for item in envelope.results {
            guard let feedUrl = item.feedUrl, feedUrl.isEmpty == false else { continue }

            let title = item.collectionName ?? feedUrl
            let author = item.artistName ?? ""
            let uuid = PodHopperFeedManager.shared.addFeedUrlStub(feedUrl: feedUrl, title: title, author: author, imageURL: item.artworkUrl600)
            guard seen.insert(uuid).inserted else { continue }

            results.append(PodcastFolderSearchResult(uuid: uuid, title: title, author: author, kind: .podcast, isLocal: false, explicit: item.collectionExplicitness == "explicit"))
        }

        return results
    }

    public func searchEpisodes(term: String, limit: Int = 50) -> [EpisodeSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let episodes = DataManager.sharedManager.findEpisodesWhere(customWhere: "title LIKE ? ESCAPE '\\' ORDER BY publishedDate DESC LIMIT \(limit)", arguments: ["%\(escaped)%"])

        var podcastTitles = [String: String]()
        return episodes.map { episode in
            let podcastUuid = episode.podcastUuid
            let podcastTitle: String
            if let cached = podcastTitles[podcastUuid] {
                podcastTitle = cached
            } else {
                podcastTitle = DataManager.sharedManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true)?.title ?? ""
                podcastTitles[podcastUuid] = podcastTitle
            }

            return EpisodeSearchResult(
                uuid: episode.uuid,
                title: episode.title ?? "",
                publishedDate: episode.publishedDate ?? Date(),
                state: episode.archived ? .archived : .normal,
                duration: episode.duration,
                podcastUuid: podcastUuid,
                podcastTitle: podcastTitle
            )
        }
    }
}
