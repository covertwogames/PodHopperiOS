import Combine
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// PodHopper's client side feed engine (persistence half).
///
/// Takes what `PodHopperFeedParser` produces and writes it into the local database the same way
/// `ServerPodcastManager.addPodcast` does, but with no Pocket Casts server in the loop. It exposes
/// the four ingestion operations the Android `SubscribeManager` exposes, with the same behavior:
///
///  - `subscribeToFeedUrl`: parse and store a subscribed podcast with its episodes, and announce
///    the subscription so the library refreshes and the (later) Supabase sync can pick it up.
///  - `addFeedUrlAsUnsubscribed`: store a NOT subscribed podcast so a page can open and play it
///    without following it. Never announces a subscription, so it cannot pull a show into the
///    subscribed library, the refresh flows or sync.
///  - `addFeedUrlStub`: insert a lightweight NOT subscribed podcast row from metadata already on
///    hand (title, author, artwork) with no network, so a page can open instantly.
///  - `fillFeedUrlEpisodes`: download and parse the feed to fill in the episodes for a stub, in the
///    background, preserving whatever subscribed state and artwork are already on screen.
///
/// Only a real subscribe announces a change, through `subscriptionChanged`. The Supabase
/// subscription sync (built later) observes that publisher and records the change into its queue,
/// exactly as the Android sync observes `subscriptionChangedRelay`.
public final class PodHopperFeedManager {

    public static let shared = PodHopperFeedManager()

    /// Emits a podcast uuid whenever that podcast becomes subscribed locally. The subscription sync
    /// observes this to enqueue an upload. Mirrors Android's `subscriptionChangedRelay`.
    public let subscriptionChanged = PassthroughSubject<String, Never>()

    private let dataManager: DataManager
    private let parseFeed: (String) -> PodHopperFeedParser.ParsedFeed?

    /// - Parameters:
    ///   - dataManager: the data store. Defaults to the shared instance; tests inject a temp one.
    ///   - parseFeed: turns a feed URL into a parsed feed. Defaults to a real network fetch and
    ///     parse; tests inject a fixture-backed closure so no network is touched.
    public init(
        dataManager: DataManager = .sharedManager,
        parseFeed: @escaping (String) -> PodHopperFeedParser.ParsedFeed? = { PodHopperFeedParser().parse(feedUrl: $0) }
    ) {
        self.dataManager = dataManager
        self.parseFeed = parseFeed
    }

    /// Deterministic podcast id for a feed URL, so callers can resolve a feed to its id without
    /// parsing (used by instant open and by the sync layer).
    public func podcastUuid(forFeed feedUrl: String) -> String {
        PodHopperUUID.podcastUuid(forFeed: feedUrl)
    }

    // MARK: Subscribe

    /// Fetch and parse a feed and store it as a subscribed podcast with its episodes. If the podcast
    /// already exists locally it is simply re-subscribed. Blocking; call off the main thread.
    public func subscribeToFeedUrl(_ feedUrl: String) {
        let uuid = PodHopperUUID.podcastUuid(forFeed: feedUrl)

        if let existing = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
            if !existing.isSubscribed() {
                existing.subscribed = 1
                dataManager.save(podcast: existing)
            }
            announceSubscribed(uuid: uuid)
            return
        }

        guard let parsed = parseFeed(feedUrl) else { return }
        parsed.podcast.subscribed = 1
        persist(parsed)
        announceSubscribed(uuid: parsed.podcast.uuid)
    }

    // MARK: Play without subscribing

    /// Fetch and parse a feed and store it as a NOT subscribed podcast with its episodes. If the
    /// podcast already exists it is left exactly as it is. Never announces a subscription. Returns
    /// the podcast uuid, or nil if the feed could not be parsed. Blocking; call off the main thread.
    @discardableResult
    public func addFeedUrlAsUnsubscribed(_ feedUrl: String) -> String? {
        let uuid = PodHopperUUID.podcastUuid(forFeed: feedUrl)

        if dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true) != nil {
            return uuid
        }

        guard let parsed = parseFeed(feedUrl) else { return nil }
        parsed.podcast.subscribed = 0
        persist(parsed)
        return parsed.podcast.uuid
    }

    // MARK: Instant open

    /// Insert a lightweight NOT subscribed podcast row from metadata already on hand, with no
    /// network, so a podcast page can open immediately. Episodes are filled in later by
    /// `fillFeedUrlEpisodes`. If the podcast already exists it is left as is. Returns the uuid.
    @discardableResult
    public func addFeedUrlStub(feedUrl: String, title: String, author: String, imageURL: String?) -> String {
        let uuid = PodHopperUUID.podcastUuid(forFeed: feedUrl)

        if dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true) == nil {
            let stub = PocketCastsDataModel.Podcast()
            stub.uuid = uuid
            stub.title = title
            stub.author = author
            stub.imageURL = imageURL
            stub.podcastUrl = feedUrl
            stub.addedDate = Date()
            stub.subscribed = 0
            dataManager.save(podcast: stub)
        }
        return uuid
    }

    /// Download and parse the feed and fill in the episodes for a stub created by `addFeedUrlStub`.
    /// No op if the podcast already has episodes, so a second open never re-parses or disturbs play
    /// state. Preserves the existing subscribed flag, added date and artwork already on screen, in
    /// case the user tapped Subscribe while the feed was still downloading. Blocking; call off the
    /// main thread.
    public func fillFeedUrlEpisodes(_ feedUrl: String) {
        let uuid = PodHopperUUID.podcastUuid(forFeed: feedUrl)

        if let current = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true),
           dataManager.findEpisodeCount(podcastId: current.id) > 0 {
            return
        }

        guard let parsed = parseFeed(feedUrl) else { return }

        if let current = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true) {
            parsed.podcast.id = current.id
            parsed.podcast.subscribed = current.subscribed
            parsed.podcast.addedDate = current.addedDate
            if current.imageURL != nil {
                parsed.podcast.imageURL = current.imageURL
            }
        } else {
            parsed.podcast.subscribed = 0
        }
        persist(parsed)
    }

    // MARK: Persistence

    /// Saves the podcast, then its episodes with the foreign keys wired to the saved podcast, the
    /// same order `ServerPodcastManager.addPodcast` uses.
    private func persist(_ parsed: PodHopperFeedParser.ParsedFeed) {
        let podcast = parsed.podcast
        dataManager.save(podcast: podcast)

        for episode in parsed.episodes {
            episode.podcastUuid = podcast.uuid
            episode.podcast_id = podcast.id
        }
        dataManager.bulkSave(episodes: parsed.episodes)
    }

    private func announceSubscribed(uuid: String) {
        // Posts the same UI notification a server subscribe would (library refresh, image precache).
        // This is a local notification only; it does not call any Pocket Casts server.
        ServerConfig.shared.syncDelegate?.podcastAdded(podcastUuid: uuid)
        ServerConfig.shared.syncDelegate?.subscribedToPodcast()
        subscriptionChanged.send(uuid)
    }
}
