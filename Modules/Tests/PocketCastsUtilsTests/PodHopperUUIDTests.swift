import XCTest
@testable import PocketCastsUtils

/// Pins PodHopper's Swift UUID derivation to ground-truth values produced by faithfully replicating
/// Android's `java.util.UUID.nameUUIDFromBytes` (MD5 version 3, no namespace). If any of these fail,
/// cross-device playback sync will not match the Android app and the Android Automotive car, so
/// nothing else in the iOS port should be trusted until this whole class passes green.
final class PodHopperUUIDTests: XCTestCase {

    // MARK: Podcast id

    func testPodcastUuidVectors() {
        XCTAssertEqual(
            PodHopperUUID.podcastUuid(forFeed: "https://feeds.megaphone.fm/example"),
            "5f4a17bf-f0d9-3607-b2a8-b8464e00d3f3"
        )
        XCTAssertEqual(
            PodHopperUUID.podcastUuid(forFeed: "http://feeds.feedburner.com/TEDTalks_audio"),
            "9eb3275e-14ef-392b-bbc1-3be25ac3da46"
        )
    }

    func testPodcastUuidTrimsWhitespace() {
        XCTAssertEqual(
            PodHopperUUID.podcastUuid(forFeed: "  https://feeds.megaphone.fm/example  "),
            PodHopperUUID.podcastUuid(forFeed: "https://feeds.megaphone.fm/example")
        )
    }

    // MARK: Episode id

    func testEpisodeUuidVectors() {
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "gid://art19-episode-locator/V0/abcdef-1234"),
            "db8acdea-6bcb-39e8-ae82-4e87c652c0e1"
        )
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "https://traffic.megaphone.fm/EP1234.mp3"),
            "00706be2-3ac6-3748-8bd4-64b97e6fb20a"
        )
    }

    func testEpisodeUuidTrimsWhitespace() {
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "  tag:soundcloud,2010:tracks/123456789  "),
            "92fe2178-cf8d-3452-89a6-5312daf38683"
        )
    }

    /// Proves the UTF-8 byte encoding matches Kotlin's `String.toByteArray()` default (UTF-8) for
    /// multibyte characters: an accented Latin char, Japanese, and an emoji.
    func testEpisodeUuidUtf8Multibyte() {
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "guid-with-accent-caf\u{00E9}-2024"),
            "d71ccb87-0d78-32f3-aebd-9ea58c7c34db"
        )
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "\u{30A8}\u{30D4}\u{30BD}\u{30FC}\u{30C9}-2024"),
            "d1379b34-708e-37c0-bc01-5b8f6ac1a4ad"
        )
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(forGuid: "emoji-\u{1F399}\u{FE0F}-ep"),
            "b06a20ea-e894-3324-a6bb-a3449c8c1fab"
        )
    }

    // MARK: Guid fallback rule

    func testEpisodeUuidFallsBackToEnclosureWhenGuidBlank() {
        let enclosure = "https://cdn.example.com/audio/ep42.mp3"
        let expected = PodHopperUUID.episodeUuid(forGuid: enclosure)
        XCTAssertEqual(PodHopperUUID.episodeUuid(guid: nil, enclosureUrl: enclosure), expected)
        XCTAssertEqual(PodHopperUUID.episodeUuid(guid: "", enclosureUrl: enclosure), expected)
        XCTAssertEqual(PodHopperUUID.episodeUuid(guid: "   ", enclosureUrl: enclosure), expected)
    }

    func testEpisodeUuidPrefersGuidWhenPresent() {
        let enclosure = "https://cdn.example.com/audio/ep42.mp3"
        let guid = "gid://art19-episode-locator/V0/abcdef-1234"
        XCTAssertEqual(
            PodHopperUUID.episodeUuid(guid: guid, enclosureUrl: enclosure),
            "db8acdea-6bcb-39e8-ae82-4e87c652c0e1"
        )
    }

    // MARK: Regression guard

    /// The trap the prompts warn about: a namespaced UUIDv3 over the same string yields a different
    /// value. If anyone ever "simplifies" the derivation to a namespaced uuid3, this fails.
    func testIsNotNamespacedV3() {
        XCTAssertNotEqual(
            PodHopperUUID.episodeUuid(forGuid: "gid://art19-episode-locator/V0/abcdef-1234"),
            "a8d737b9-6a31-3576-8ede-6310c9eb6891"
        )
    }
}
