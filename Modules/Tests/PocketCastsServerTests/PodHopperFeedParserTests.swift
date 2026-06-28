import XCTest
@testable import PocketCastsServer
import PocketCastsDataModel
import PocketCastsUtils

/// Verifies PodHopper's feed parser produces the right model objects with the right deterministic
/// ids, on both the strict (FeedKit) path and the lenient (XMLParser) fallback. The id values are
/// pinned to the same algorithm the Android app and the car use, so a regression here would mean
/// episodes parsed on iOS would not match across platforms for sync.
final class PodHopperFeedParserTests: XCTestCase {

    private let feedUrl = "https://feeds.example.com/podhopper-test"

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"),
            "missing fixture \(name).xml"
        )
        return try Data(contentsOf: url)
    }

    // MARK: Strict path (FeedKit)

    func testWellFormedFeedParsesViaFeedKit() throws {
        let parser = PodHopperFeedParser()
        let data = try loadFixture("podhopper_feed_wellformed")
        let parsed = try XCTUnwrap(parser.parse(data: data, feedUrl: feedUrl))

        // Podcast identity and mapped fields.
        XCTAssertEqual(parsed.podcast.uuid, "83dee859-7374-3e77-a276-83cd2de17415")
        XCTAssertEqual(parsed.podcast.uuid, PodHopperUUID.podcastUuid(forFeed: feedUrl))
        XCTAssertEqual(parsed.podcast.title, "PodHopper Test Show")
        XCTAssertEqual(parsed.podcast.podcastUrl, feedUrl)
        XCTAssertEqual(parsed.podcast.author, "Test Author")
        XCTAssertEqual(parsed.podcast.imageURL, "https://img.example.com/show.jpg") // itunes image preferred
        XCTAssertEqual(parsed.podcast.subscribed, 1)

        // Episodes.
        XCTAssertEqual(parsed.episodes.count, 2)

        let ep1 = parsed.episodes[0]
        XCTAssertEqual(ep1.uuid, "bc8ba3fe-6641-3156-985b-53f2e320128e")
        XCTAssertEqual(ep1.podcastUuid, parsed.podcast.uuid)
        XCTAssertEqual(ep1.title, "Episode One")
        XCTAssertEqual(ep1.downloadUrl, "https://cdn.example.com/ep1.mp3")
        XCTAssertEqual(ep1.sizeInBytes, 1000)
        XCTAssertEqual(ep1.fileType, "audio/mpeg")
        XCTAssertEqual(ep1.duration, 3723, accuracy: 0.001) // 1:02:03
        XCTAssertEqual(ep1.playingStatus, PlayingStatus.notPlayed.rawValue)
        XCTAssertEqual(ep1.episodeStatus, DownloadStatus.notDownloaded.rawValue)

        let ep2 = parsed.episodes[1]
        XCTAssertEqual(ep2.uuid, "f1b4f9e7-88ee-3cfd-afca-37da00e0a9ad")
        XCTAssertEqual(ep2.duration, 600, accuracy: 0.001)

        // Latest episode pointer is the newest by published date (Episode Two, Jan 2).
        XCTAssertEqual(parsed.podcast.latestEpisodeUuid, "f1b4f9e7-88ee-3cfd-afca-37da00e0a9ad")
    }

    // MARK: Lenient path (XMLParser fallback)

    func testLenientFeedParses() throws {
        let parser = PodHopperFeedParser()
        let data = try loadFixture("podhopper_feed_lenient")
        let parsed = try XCTUnwrap(parser.parseLeniently(data: data, feedUrl: feedUrl))

        XCTAssertEqual(parsed.podcast.uuid, PodHopperUUID.podcastUuid(forFeed: feedUrl))
        XCTAssertEqual(parsed.podcast.title, "Lenient Test Show")
        XCTAssertEqual(parsed.podcast.author, "Lenient Author")
        XCTAssertEqual(parsed.podcast.imageURL, "https://img.example.com/lenient.jpg")

        XCTAssertEqual(parsed.episodes.count, 2)

        // Episode with a guid: id derived from the guid, description from content:encoded CDATA.
        let ep1 = parsed.episodes[0]
        XCTAssertEqual(ep1.uuid, "5dac40bd-6510-38f7-a272-788e58ae7b2b")
        XCTAssertEqual(ep1.title, "Lenient Episode One")
        XCTAssertEqual(ep1.episodeDescription, "<p>Rich <b>HTML</b> body.</p>")
        XCTAssertEqual(ep1.downloadUrl, "https://cdn.example.com/lenient1.mp3")
        XCTAssertEqual(ep1.duration, 90, accuracy: 0.001) // 1:30

        // Episode without a guid: id falls back to the enclosure URL, matching Android.
        let ep2 = parsed.episodes[1]
        XCTAssertEqual(ep2.uuid, "dfcb5b6f-8aa5-3057-a383-bcf1d0324dc1")
        XCTAssertEqual(ep2.uuid, PodHopperUUID.episodeUuid(guid: nil, enclosureUrl: "https://cdn.example.com/lenient2.mp3"))
    }

    // MARK: Field parsing units

    func testParseDurationFormats() {
        XCTAssertEqual(PodHopperFeedParser.parseDuration("1:02:03"), 3723, accuracy: 0.001)
        XCTAssertEqual(PodHopperFeedParser.parseDuration("12:30"), 750, accuracy: 0.001)
        XCTAssertEqual(PodHopperFeedParser.parseDuration("45"), 45, accuracy: 0.001)
        XCTAssertEqual(PodHopperFeedParser.parseDuration(""), 0, accuracy: 0.001)
    }

    func testParsePubDate() throws {
        let date = try XCTUnwrap(PodHopperFeedParser.parsePubDate("Wed, 01 Jan 2025 10:00:00 +0000"))
        XCTAssertEqual(date.timeIntervalSince1970, 1735725600, accuracy: 1)
        XCTAssertNil(PodHopperFeedParser.parsePubDate(""))
    }
}
