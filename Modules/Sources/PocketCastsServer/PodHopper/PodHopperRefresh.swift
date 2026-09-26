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
    /// one podcast at a time, while not opening an unbounded number of connections. Matches Android.
    private static let maxConcurrentFeedRefreshes = 6

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

    /// Parse each podcast's feed and build a refresh response keyed by podcast uuid containing every
    /// episode found in the feed. Blocking until all feeds are parsed, so call it off the main thread.
    /// Podcasts without a feed url, or whose feed cannot be fetched or parsed, are simply skipped and
    /// contribute no updates rather than failing the whole refresh. Returning all episodes per podcast
    /// is intentional: the downstream `RefreshOperation` discards the ones already stored.
    static func refreshResponse(for podcasts: [Podcast]) -> PodcastRefreshResponse {
        // PodHopper: drop anything staged by an earlier refresh that never reached the save step, so
        // this run can only ever commit validators for feeds it fetched itself. Without this, a
        // refresh that was abandoned before saving could have its validators committed later by an
        // unrelated refresh, and those feeds would be treated as up to date without their episodes.
        PodHopperFeedValidators.shared.discardStaged()

        let parser = PodHopperFeedParser()
        let permits = DispatchSemaphore(value: maxConcurrentFeedRefreshes)
        let group = DispatchGroup()
        let lock = NSLock()
        var updates = [String: [RefreshEpisode]]()

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
                // staged here; `RefreshOperation` commits them once the episodes are saved.
                switch parser.fetch(feedUrl: feedUrl, conditional: true, maxEpisodes: episodeLimit) {
                case .notModified:
                    return
                case .failure:
                    return
                case let .success(parsed, validators):
                    if let validators = validators {
                        PodHopperFeedValidators.shared.stage(validators, for: feedUrl)
                    }
                    guard !parsed.episodes.isEmpty else { return }
                    let refreshEpisodes = parsed.episodes.map(refreshEpisode(from:))

                    lock.lock()
                    updates[uuid] = refreshEpisodes
                    lock.unlock()
                }
            }
        }

        group.wait()

        var response = PodcastRefreshResponse()
        response.status = "ok"
        response.result = RefreshResult(podcastUpdates: updates)
        return response
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
