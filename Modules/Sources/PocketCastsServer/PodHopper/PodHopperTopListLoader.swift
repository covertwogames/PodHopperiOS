import CryptoKit
import Foundation

/// Loads the public iTunes "top podcasts" chart for the PodHopper Discover page, and resolves a
/// chart entry to its real RSS feed url.
///
/// This is a direct port of the Android `ItunesTopListLoader`, trimmed to iTunes only. The chart
/// feed (Apple's marketing RSS) does not hand back the podcast's RSS url. Each entry only carries an
/// iTunes numeric id, so the real feed url is resolved with a second "lookup" call when the user
/// acts on a tile. No API key is required for either call.
///
/// A fixed buffer of `fetchLimit` entries is always fetched, then any entry on the local blocklist
/// is removed, the remainder is shuffled, and only the requested number is returned. The buffer is
/// what lets a removed entry be backfilled so the grid stays full, and the shuffle is what keeps the
/// result from reading as a straight top down ranking.
public final class PodHopperTopListLoader {
    public static let shared = PodHopperTopListLoader()

    public struct TopPodcast {
        public let title: String
        public let author: String
        public let imageUrl: String?
        /// Apple's numeric show id. Stable across renames, so it is what the blocklist matches on.
        public let itunesId: String
        /// iTunes lookup url for this entry. Resolve it with `resolveFeedUrl` to get the RSS url.
        public let lookupUrl: String
    }

    private let session: URLSession

    /// Normalized SHA-256 hashes of podcasts to keep out of suggestions. Loaded once from an optional
    /// bundled resource; if the resource is not present, nothing is filtered. This mirrors the
    /// Android asset, which is git ignored and only present on the build machine.
    private lazy var blockedHashes: Set<String> = loadBlockedHashes()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Loads up to `limit` top podcasts for `country` (a two letter ISO country code), with blocked
    /// entries removed and the rest shuffled. Falls back to the US chart if the requested country's
    /// chart cannot be fetched. Returns an empty list on failure rather than throwing.
    public func loadTopList(country: String, limit: Int) async -> [TopPodcast] {
        let fetched = await fetchWithFallback(country: country, limit: Self.fetchLimit)
        let visible = fetched.filter { isBlocked($0) == false }
        return Array(visible.shuffled().prefix(limit))
    }

    /// Resolves an iTunes `lookupUrl` (from `TopPodcast.lookupUrl`) to the podcast's real RSS feed
    /// url. Returns nil if the lookup fails or the entry has no feed url.
    public func resolveFeedUrl(_ lookupUrl: String) async -> String? {
        guard let url = URL(string: lookupUrl) else { return nil }
        do {
            let (data, response) = try await session.data(for: request(for: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let feedUrl = first["feedUrl"] as? String,
                  feedUrl.isEmpty == false else {
                return nil
            }
            return feedUrl
        } catch {
            return nil
        }
    }

    private func fetchWithFallback(country: String, limit: Int) async -> [TopPodcast] {
        if let primary = await fetchChart(country: country, limit: limit) {
            return primary
        }
        if country.uppercased() != "US", let fallback = await fetchChart(country: "US", limit: limit) {
            return fallback
        }
        return []
    }

    private func fetchChart(country: String, limit: Int) async -> [TopPodcast]? {
        let urlString = "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)/explicit=true/json"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await session.data(for: request(for: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseChart(data)
        } catch {
            return nil
        }
    }

    private func parseChart(_ data: Data) -> [TopPodcast] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any],
              let entries = feed["entry"] as? [[String: Any]] else {
            return []
        }
        var results = [TopPodcast]()
        for entry in entries {
            let title = label(entry["im:name"])
            if title.isEmpty {
                continue
            }
            let itunesId = string(((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"])
            if itunesId.isEmpty {
                continue
            }
            results.append(
                TopPodcast(
                    title: title,
                    author: label(entry["im:artist"]),
                    imageUrl: largestImage(entry),
                    itunesId: itunesId,
                    lookupUrl: "https://itunes.apple.com/lookup?id=\(itunesId)"
                )
            )
        }
        return results
    }

    private func largestImage(_ entry: [String: Any]) -> String? {
        guard let images = entry["im:image"] as? [[String: Any]] else { return nil }
        var chosen: String?
        for image in images {
            let height = Int(string((image["attributes"] as? [String: Any])?["height"])) ?? 0
            let value = string(image["label"])
            if height >= 100 {
                return value.isEmpty ? chosen : value
            }
            if value.isEmpty == false {
                chosen = value
            }
        }
        return chosen
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("PodHopper", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func label(_ node: Any?) -> String {
        string((node as? [String: Any])?["label"])
    }

    private func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private func loadBlockedHashes() -> Set<String> {
        guard let url = Bundle.main.url(forResource: Self.blocklistResource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let hashes = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
            .map { $0.lowercased() }
        return Set(hashes)
    }

    private func isBlocked(_ podcast: TopPodcast) -> Bool {
        if blockedHashes.isEmpty {
            return false
        }
        let idHash = sha256Hex(podcast.itunesId.trimmingCharacters(in: .whitespaces))
        let normalizedTitle = podcast.title.lowercased().replacingOccurrences(
            of: "[^a-z0-9]",
            with: "",
            options: .regularExpression
        )
        let titleHash = sha256Hex(normalizedTitle)
        return blockedHashes.contains(idHash) || blockedHashes.contains(titleHash)
    }

    private func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let fetchLimit = 60
    private static let blocklistResource = "discover_blocklist"
}
