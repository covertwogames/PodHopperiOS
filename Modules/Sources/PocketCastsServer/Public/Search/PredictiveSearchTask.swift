import Foundation

struct PredictiveSearchEnvelope: Decodable {
    public let results: [PredictiveSearchResult]
}

public struct PredictivePodcastSearchResult: Codable, Hashable {
    public let uuid: String
    let title: String
    let author: String
    public let isExplicit: Bool?

    enum CodingKeys: String, CodingKey {
        case uuid, title, author
        case isExplicit = "explicit"
    }
}

public enum PredictiveSearchResultType: Hashable {
    case unknown(String)
    case term(String)
    case podcast(PredictivePodcastSearchResult)
}

public struct PredictiveSearchResult: Decodable, Hashable {
    public let type: PredictiveSearchResultType

    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
            case "term":
                let value = try container.decode(String.self, forKey: .value)
                self.type = .term(value)
            case "podcast":
                let podcast = try container.decode(PredictivePodcastSearchResult.self, forKey: .value)
                self.type = .podcast(podcast)
            default:
                let value = try container.decode(String.self, forKey: .value)
                self.type = .unknown(value)
        }
    }

    /// PodHopper: init used by the on-device iTunes predictive search backend.
    init(type: PredictiveSearchResultType) {
        self.type = type
    }
}

public class PredictiveSearchTask {
    public init(session: URLSession = .shared) {}

    /// PodHopper: predictive suggestions come from a small iTunes search instead of the
    /// Pocket Casts autocomplete server.
    public func search(term: String) async throws -> [PredictiveSearchResult] {
        let podcasts = try await PodHopperSearch.shared.searchPodcasts(term: term, limit: 6)
        return podcasts.map { podcast in
            PredictiveSearchResult(type: .podcast(PredictivePodcastSearchResult(uuid: podcast.uuid, title: podcast.title ?? "", author: podcast.author ?? "", isExplicit: podcast.explicit)))
        }
    }
}
