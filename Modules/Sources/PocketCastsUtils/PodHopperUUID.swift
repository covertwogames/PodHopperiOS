import CryptoKit
import Foundation

/// PodHopper's deterministic identity derivation.
///
/// Podcasts and episodes have no server-assigned ids in PodHopper. Their ids are computed from
/// feed data so the same feed and the same episode produce the same id on every device and every
/// platform. That is what lets iOS, Android, and the Android Automotive car share one synced
/// library through Supabase with no server in the loop.
///
/// The derivation must match the Android client exactly, byte for byte. Android uses Java's
/// `UUID.nameUUIDFromBytes`, which is a version 3 (MD5) name-based UUID with no namespace: it
/// MD5 hashes the UTF-8 bytes of the input string, sets the version nibble to 3 and the IETF
/// variant bits, then formats the result as a lowercase hyphenated UUID string. This file
/// reproduces that precisely.
///
/// Do NOT replace this with a namespaced UUIDv3 (for example a uuid3 over a namespace plus the
/// string). That produces different output and would silently break cross-device playback sync.
/// The test `testIsNotNamespacedV3` guards against exactly that regression.
public enum PodHopperUUID {

    /// Deterministic podcast id derived from the feed URL.
    ///
    /// Mirrors Android `FeedParser.podcastUuidForFeed`:
    /// `UUID.nameUUIDFromBytes(("podhopper-feed:" + feedUrl.trim()).toByteArray())`.
    public static func podcastUuid(forFeed feedUrl: String) -> String {
        nameUUIDFromBytes("podhopper-feed:" + feedUrl.podhopperTrimmed())
    }

    /// Deterministic episode id derived from its RSS guid.
    ///
    /// Mirrors Android `FeedParser.episodeUuidFor`:
    /// `UUID.nameUUIDFromBytes(("podhopper-episode:" + guid.trim()).toByteArray())`.
    public static func episodeUuid(forGuid guid: String) -> String {
        nameUUIDFromBytes("podhopper-episode:" + guid.podhopperTrimmed())
    }

    /// Deterministic episode id with the Android guid fallback rule applied: use the RSS guid when
    /// it is present and not blank, otherwise fall back to the audio enclosure URL.
    ///
    /// Mirrors Android `FeedParser.mapEpisode`:
    /// `val guid = item.guid?.guid?.takeIf { it.isNotBlank() } ?: audioUrl`.
    /// "Blank" means empty or whitespace only, matching Kotlin `String.isNotBlank`.
    public static func episodeUuid(guid: String?, enclosureUrl: String) -> String {
        if let guid, !guid.podhopperTrimmed().isEmpty {
            return episodeUuid(forGuid: guid)
        }
        return episodeUuid(forGuid: enclosureUrl)
    }

    /// Faithful reproduction of `java.util.UUID.nameUUIDFromBytes`: MD5 over the UTF-8 bytes of the
    /// input, version 3, IETF variant, formatted lowercase and hyphenated.
    private static func nameUUIDFromBytes(_ string: String) -> String {
        var digest = Array(Insecure.MD5.hash(data: Data(string.utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x30 // clear version, set to version 3
        digest[8] = (digest[8] & 0x3F) | 0x80 // clear variant, set to IETF variant
        return String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            digest[6], digest[7],
            digest[8], digest[9],
            digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        )
    }
}

private extension String {
    /// Matches Kotlin `String.trim()`: removes leading and trailing whitespace. The values that
    /// feed the hash (feed URL and guid) are trimmed before hashing, on both platforms, so the
    /// bytes line up.
    func podhopperTrimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
