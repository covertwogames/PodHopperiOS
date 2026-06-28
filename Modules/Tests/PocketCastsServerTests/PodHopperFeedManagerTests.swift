import Combine
import GRDB
import XCTest
@testable import PocketCastsServer
@testable import PocketCastsDataModel
@testable import PocketCastsUtils

/// Exercises the four feed operations against a real (temporary) database, with the parse step fed
/// from a fixture so no network is touched. Asserts the persistence and, critically, that only a
/// real subscribe announces a subscription change, matching the Android SubscribeManager.
final class PodHopperFeedManagerTests: XCTestCase {

    private var dataManager: DataManager!
    private let feedUrl = "https://feeds.example.com/podhopper-test"

    override func setUp() {
        super.setUp()
        dataManager = DataManager(dbQueue: GRDBQueue(dbPool: try! DatabasePool(path: NSTemporaryDirectory().appending("\(UUID().uuidString).sqlite"))))
        DataManager.sharedManager = dataManager
    }

    override func tearDown() {
        FeatureFlagMock().reset()
        super.tearDown()
    }

    private func fixtureParse() -> PodHopperFeedParser.ParsedFeed? {
        guard let url = Bundle.module.url(forResource: "podhopper_feed_wellformed", withExtension: "xml", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PodHopperFeedParser().parse(data: data, feedUrl: feedUrl)
    }

    private func makeManager() -> PodHopperFeedManager {
        PodHopperFeedManager(dataManager: dataManager, parseFeed: { [weak self] _ in self?.fixtureParse() })
    }

    private var uuid: String { PodHopperUUID.podcastUuid(forFeed: feedUrl) }

    func testSubscribePersistsPodcastAndEpisodesAndAnnouncesOnce() {
        let manager = makeManager()
        var announced: [String] = []
        let cancellable = manager.subscriptionChanged.sink { announced.append($0) }
        defer { cancellable.cancel() }

        manager.subscribeToFeedUrl(feedUrl)

        let podcast = try? XCTUnwrap(dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true))
        XCTAssertNotNil(podcast)
        XCTAssertTrue(podcast!.isSubscribed())
        XCTAssertEqual(podcast!.title, "PodHopper Test Show")
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: podcast!.id), 2)

        // Episodes are wired to the saved podcast.
        let episode = dataManager.findEpisode(uuid: "bc8ba3fe-6641-3156-985b-53f2e320128e")
        XCTAssertNotNil(episode)
        XCTAssertEqual(episode!.podcast_id, podcast!.id)
        XCTAssertEqual(episode!.podcastUuid, uuid)

        XCTAssertEqual(announced, [uuid])
    }

    func testAddAsUnsubscribedPersistsWithoutAnnouncing() {
        let manager = makeManager()
        var announced: [String] = []
        let cancellable = manager.subscriptionChanged.sink { announced.append($0) }
        defer { cancellable.cancel() }

        let returned = manager.addFeedUrlAsUnsubscribed(feedUrl)
        XCTAssertEqual(returned, uuid)

        let podcast = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)
        XCTAssertNotNil(podcast)
        XCTAssertFalse(podcast!.isSubscribed())
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: podcast!.id), 2)
        XCTAssertTrue(announced.isEmpty)
    }

    func testStubOpensInstantlyThenFillPopulates() {
        let manager = makeManager()

        let returned = manager.addFeedUrlStub(feedUrl: feedUrl, title: "Stub Title", author: "Stub Author", imageURL: "https://img.example.com/stub.jpg")
        XCTAssertEqual(returned, uuid)

        // Stub is present, unsubscribed, with no episodes yet.
        let stub = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)
        XCTAssertNotNil(stub)
        XCTAssertFalse(stub!.isSubscribed())
        XCTAssertEqual(stub!.title, "Stub Title")
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: stub!.id), 0)

        // Fill populates episodes and keeps the unsubscribed state.
        manager.fillFeedUrlEpisodes(feedUrl)
        let filled = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)
        XCTAssertNotNil(filled)
        XCTAssertFalse(filled!.isSubscribed())
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: filled!.id), 2)
    }

    func testFillIsNoOpWhenEpisodesAlreadyExist() {
        let manager = makeManager()
        manager.subscribeToFeedUrl(feedUrl) // now subscribed with 2 episodes

        let before = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)!
        manager.fillFeedUrlEpisodes(feedUrl) // should do nothing
        let after = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)!

        XCTAssertTrue(after.isSubscribed()) // subscribed state untouched
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: after.id), 2)
    }

    func testResubscribeExistingUnsubscribedFlipsAndAnnouncesWithoutDuplicating() {
        let manager = makeManager()
        manager.addFeedUrlAsUnsubscribed(feedUrl) // creates an unsubscribed podcast with episodes

        var announced: [String] = []
        let cancellable = manager.subscriptionChanged.sink { announced.append($0) }
        defer { cancellable.cancel() }

        manager.subscribeToFeedUrl(feedUrl)

        let podcast = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true)!
        XCTAssertTrue(podcast.isSubscribed())
        XCTAssertEqual(announced, [uuid])
        XCTAssertEqual(dataManager.findEpisodeCount(podcastId: podcast.id), 2) // no duplicate episodes
    }
}
