import Foundation
import PocketCastsDataModel

public struct PodcastFolderSearchResult: Codable, Hashable {
    public let uuid: String
    public let title: String?
    public let author: String?
    public let kind: Kind
    public var isLocal: Bool?
    public var explicit: Bool?

    enum CodingKeys: String, CodingKey {
        case uuid, title, author, kind, isLocal, explicit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = try container.decode(String.self, forKey: .uuid)
        self.title = try? container.decode(String.self, forKey: .title)
        self.author = try? container.decode(String.self, forKey: .author)
        self.kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .podcast
        self.isLocal = (try? container.decode(Bool.self, forKey: .isLocal)) ?? false
        self.explicit = try? container.decodeIfPresent(Bool.self, forKey: .explicit)
    }

    /// PodHopper: memberwise init used by the on-device iTunes search backend.
    init(uuid: String, title: String?, author: String?, kind: Kind, isLocal: Bool?, explicit: Bool?) {
        self.uuid = uuid
        self.title = title
        self.author = author
        self.kind = kind
        self.isLocal = isLocal
        self.explicit = explicit
    }

    public init?(from podcast: Podcast) {
        self.uuid = podcast.uuid
        self.title = podcast.title
        self.author = podcast.author
        self.isLocal = true
        self.kind = .podcast
        self.explicit = podcast.isExplicit
    }

    public init?(from folder: Folder) {
        self.uuid = folder.uuid
        self.title = folder.name
        self.author = ""
        self.isLocal = true
        self.kind = .folder
        self.explicit = false
    }

    public init?(from predictiveResult: PredictiveSearchResult) {
        switch predictiveResult.type {
            case .podcast(let podcast):
                self.uuid = podcast.uuid
                self.author = podcast.author
                self.title = podcast.title
                self.kind = .podcast
                self.isLocal = false
                self.explicit = podcast.isExplicit
            default:
                return nil
        }
    }

    public init?(from combinedResult: CombinedSearchResult) {
        guard combinedResult.type == "podcast" else {
            return nil
        }
        self.uuid = combinedResult.uuid
        self.author = combinedResult.author
        self.title = combinedResult.title
        self.kind = .podcast
        self.isLocal = false
        self.explicit = combinedResult.explicit
    }

    public enum Kind: Codable {
        case podcast, folder
    }

    public static func ==(lhs: PodcastFolderSearchResult, rhs: PodcastFolderSearchResult) -> Bool {
        lhs.kind == rhs.kind && lhs.uuid == rhs.uuid
    }
}

extension PodcastFolderSearchResult: Identifiable {
    public var id: String {
        uuid
    }
}

public class PodcastSearchTask {
    public init(session: URLSession = .shared) {}

    /// PodHopper: podcast search runs against the iTunes Search API on device instead of the
    /// Pocket Casts search servers.
    public func search(term: String) async throws -> [PodcastFolderSearchResult] {
        try await PodHopperSearch.shared.searchPodcasts(term: term)
    }
}

extension Int {
    // Return a correspondent poll waiting time for a given number
    // From 1 to 2: 2 seconds
    // From 3 to 6: 5 second
    // For 7: 10 seconds
    // Others: -1
    var pollWaitingTime: TimeInterval {
        switch self {
        case 1..<3:
            2
        case 3..<7:
            5
        case 7:
            10
        default:
            -1
        }
    }
}
