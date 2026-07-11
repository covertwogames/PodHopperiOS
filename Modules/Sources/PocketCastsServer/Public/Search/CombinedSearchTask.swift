import Foundation

public enum CombinedSearchResultType: Hashable {
    case episode(EpisodeSearchResult)
    case podcast(PodcastFolderSearchResult)
}

public struct CombinedSearchResult: Decodable, Hashable {
    public let type: String
    public let uuid: String
    public let title: String
    public let publishedDate: Date?
    public let duration: Double?
    public let podcastUuid: String?
    public let podcastTitle: String?
    public let author: String?
    public let explicit: Bool?

    public var resolvedResultType: CombinedSearchResultType? {
        switch type {
            case "podcast":
                guard let podcast = PodcastFolderSearchResult(from: self) else {
                    return nil
                }
                return .podcast(podcast)
            case "episode":
            let episode = EpisodeSearchResult(uuid: self.uuid, title: self.title, publishedDate: self.publishedDate ?? Date.now, state: .normal, duration: duration, podcastUuid: self.podcastUuid ?? "", podcastTitle: self.podcastTitle ?? "")
                return .episode(episode)
            default:
                return nil
        }
    }
}

public class CombinedSearchTask {
    public init(session: URLSession = .shared) {}

    /// PodHopper: combines the on-device iTunes podcast search with a local database episode
    /// search instead of calling the Pocket Casts combined search endpoint.
    public func search(term: String) async throws -> [CombinedSearchResultType] {
        let podcasts = try await PodHopperSearch.shared.searchPodcasts(term: term, limit: 20)
        let episodes = PodHopperSearch.shared.searchEpisodes(term: term, limit: 30)

        var results: [CombinedSearchResultType] = podcasts.map { .podcast($0) }
        results.append(contentsOf: episodes.map { .episode($0) })

        return results
    }
}
