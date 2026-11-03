import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// PodHopper refreshes subscribed podcasts by re-fetching their RSS feeds on device and producing the
/// same `PodcastRefreshResponse` the Pocket Casts refresh server used to return. The existing
/// `RefreshOperation` then inserts only the genuinely new episodes, because it dedups by episode uuid
/// and PodHopper episode uuids are derived deterministically from each item's guid. This is the iOS
/// counterpart to Android's `FeedRefreshManager.refreshPodcastsLocally`: the central refresh path and
/// all its downstream processing stay exactly the same, only the source of the data moves from the
/// server to the feeds.
enum PodHopperRefresh {

    /// How many feeds to fetch at once. Bounded so the network waits overlap instead of stacking up
    /// one podcast at a time, while only a few whole feeds are held in memory at once: a long running
    /// show's feed can parse into thousands of episodes. Matches Android.
    private static let maxConcurrentFeedRefreshes = 3

    /// How many episode uuids go into each "already stored?" database lookup, keeping each query small
    /// however long the feed is.
    private static let storedEpisodeLookupBatchSize = 500

    /// PodHopper: the watch keeps only the newest episodes of each podcast, so a feed with thousands
    /// of them costs it a handful of episode objects instead of thousands. The phone and car keep
    /// the whole feed, as before.
    private static var episodeLimit: Int? {
        #if os(watchOS)
            return PodHopperFeedParser.watchEpisodeCap
        #else
            return nil
        #endif
    }

    /// Parse each podcast's feed and build a refresh response keyed by podcast uuid containing the
    /// feed's episodes that aren't stored yet. Blocking until all feeds are parsed, so call it off the
    /// main thread. Podcasts without a feed url, or whose feed cannot be fetched or parsed, are simply
    /// skipped and contribute no updates rather than failing the whole refresh. A feed that changed but
    /// has nothing new still gets an (empty) entry, so `RefreshOperation` handles that podcast exactly
    /// as it did when every episode was passed along, and it still checks each episode it's given.
    static func refreshResponse(for podcasts: [Podcast]) -> PodcastRefreshResponse {
        let parser = PodHopperFeedParser()
        let permits = DispatchSemaphore(value: maxConcurrentFeedRefreshes)
        let group = DispatchGroup()
        let lock = NSLock()
        var updates = [String: [RefreshEpisode]]()
        // PodHopper: the validators this refresh received travel with its result and are saved by
        // `RefreshOperation` only after the episodes are, so a refresh that never gets that far saves
        // nothing, and refreshes running alongside each other keep their validators apart.
        var feedValidators = [String: PodHopperFeedValidators.Validators]()

        for podcast in podcasts {
            guard let feedUrl = podcast.podcastUrl, !feedUrl.isEmpty else { continue }
            let uuid = podcast.uuid

            permits.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    permits.signal()
                    group.leave()
                }

                // PodHopper: ask the host whether the feed changed. An unchanged feed costs nothing
                // beyond the round trip: no body, no parse, no database work. Validators are only
                // collected here; `RefreshOperation` saves them once the episodes are saved.
                switch parser.fetch(feedUrl: feedUrl, conditional: true, maxEpisodes: episodeLimit) {
                case .notModified:
                    return
                case .failure:
                    return
                case let .success(parsed, validators):
                    if let validators = validators, !validators.isEmpty {
                        lock.lock()
                        feedValidators[feedUrl] = validators
                        lock.unlock()
                    }
                    guard !parsed.episodes.isEmpty else { return }
                    // PodHopper: keep only the episodes that aren't stored yet as each feed finishes,
                    // instead of holding every episode of every changed feed until all feeds are done.
                    let storedUuids = storedEpisodeUuids(among: parsed.episodes)
                    let refreshEpisodes = parsed.episodes
                        .filter { !storedUuids.contains($0.uuid) }
                        .map(refreshEpisode(from:))

                    lock.lock()
                    updates[uuid] = refreshEpisodes
                    lock.unlock()
                }
            }
        }

        group.wait()

        var response = PodcastRefreshResponse()
        response.status = "ok"
        response.result = RefreshResult(podcastUpdates: updates, feedValidators: feedValidators)
        return response
    }

    /// The uuids among `episodes` that are already in the database, using the same check as
    /// `RefreshOperation` (an episode with that uuid exists anywhere). If a lookup fails it finds
    /// nothing, so nothing is dropped here and `RefreshOperation` still does the final check.
    private static func storedEpisodeUuids(among episodes: [Episode]) -> Set<String> {
        let uuids = episodes.map(\.uuid).filter { !$0.isEmpty }
        var stored = Set<String>()
        var start = 0
        while start < uuids.count {
            let end = min(start + storedEpisodeLookupBatchSize, uuids.count)
            stored.formUnion(DataManager.sharedManager.findMatchingEpisodes(uuids: Array(uuids[start ..< end])))
            start = end
        }
        return stored
    }

    /// Map a parsed feed episode onto the response DTO the refresh pipeline consumes. The published
    /// date is written with the same formatter the pipeline uses to read it back, so the date round
    /// trips exactly. Fields the feed does not carry (detailed description, episode type, season and
    /// episode numbers) are left nil and default the same way a sparse server response would.
    private static func refreshEpisode(from episode: Episode) -> RefreshEpisode {
        RefreshEpisode(
            title: episode.title,
            uuid: episode.uuid,
            url: episode.downloadUrl,
            episodeDescription: episode.episodeDescription,
            fileType: episode.fileType,
            sizeInBytes: episode.sizeInBytes,
            duration: episode.duration,
            publishedDate: DateFormatHelper.sharedHelper.jsonFormat(episode.publishedDate)
        )
    }
}
