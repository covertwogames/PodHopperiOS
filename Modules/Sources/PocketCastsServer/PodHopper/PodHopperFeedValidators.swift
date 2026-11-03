import Foundation

/// PodHopper: remembers what a feed looked like the last time we read it, so a refresh can ask the
/// host "has this changed?" instead of downloading and parsing the whole feed again.
///
/// Hosts answer with an `ETag` and/or a `Last-Modified` date. Sending those back as
/// `If-None-Match` / `If-Modified-Since` lets a host reply "not modified" with no body at all, which
/// skips the download, the parse and the database work. This mirrors Android's feed validator store.
///
/// A refresh holds the validators it receives in its own result and only writes them here once the
/// episodes from those fetches have actually been saved. If the app dies in between, nothing is
/// written, so the next refresh fetches the feed in full rather than believing it is already up to date.
public final class PodHopperFeedValidators {
    public static let shared = PodHopperFeedValidators()

    public struct Validators {
        public let etag: String?
        public let lastModified: String?

        public init(etag: String?, lastModified: String?) {
            self.etag = etag
            self.lastModified = lastModified
        }

        var isEmpty: Bool {
            (etag?.isEmpty ?? true) && (lastModified?.isEmpty ?? true)
        }
    }

    static let suiteName = "podhopper_feed_validators"
    private static let etagPrefix = "etag_"
    private static let lastModifiedPrefix = "last_modified_"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: PodHopperFeedValidators.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    /// What the host told us last time, or nil if we have never stored anything for this feed.
    public func stored(for feedUrl: String) -> Validators? {
        let etag = defaults.string(forKey: Self.etagPrefix + feedUrl)
        let lastModified = defaults.string(forKey: Self.lastModifiedPrefix + feedUrl)
        let validators = Validators(etag: etag, lastModified: lastModified)
        return validators.isEmpty ? nil : validators
    }

    /// Write straight away, for callers that save the episodes themselves before calling this.
    public func store(_ validators: Validators, for feedUrl: String) {
        guard !validators.isEmpty else { return }
        write(validators, for: feedUrl)
    }

    /// Forget this feed. Called when a podcast is unsubscribed, so re-adding it fetches in full
    /// rather than being told "not modified" when we no longer hold its episodes.
    public func clear(for feedUrl: String) {
        guard !feedUrl.isEmpty else { return }
        defaults.removeObject(forKey: Self.etagPrefix + feedUrl)
        defaults.removeObject(forKey: Self.lastModifiedPrefix + feedUrl)
    }

    private func write(_ validators: Validators, for feedUrl: String) {
        if let etag = validators.etag, !etag.isEmpty {
            defaults.set(etag, forKey: Self.etagPrefix + feedUrl)
        } else {
            defaults.removeObject(forKey: Self.etagPrefix + feedUrl)
        }

        if let lastModified = validators.lastModified, !lastModified.isEmpty {
            defaults.set(lastModified, forKey: Self.lastModifiedPrefix + feedUrl)
        } else {
            defaults.removeObject(forKey: Self.lastModifiedPrefix + feedUrl)
        }
    }
}
