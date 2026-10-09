import Foundation
import PocketCastsUtils

extension L10n {
    // MARK: Proper Nouns

    /// These strings are proper nouns and shouldn't be localized
    static let appleWatch = "Apple Watch"
    static let pocketCasts = "PodHopper"
    static let pocketCastsShort = "Hopper"

    // MARK: Helper Functions

    static func podcastCount(_ count: Int, capitalized: Bool = false) -> String {
        let result = count == 1 ? L10n.podcastCountSingular : L10n.podcastCountPluralFormat(count.localized())
        return capitalized ? result.localizedCapitalized : result
    }

    static func downloadedFilesConf(_ count: Int) -> String {
        count == 1 ? L10n.downloadedFilesConfSingular : L10n.downloadedFilesConfPluralFormat(count.localized())
    }

    static func selectedPodcastCount(_ count: Int, capitalized: Bool = false) -> String {
        let result: String
        if count == 0 {
            result = L10n.settingsAutoDownloadsNoPodcastsSelected
        } else if count == 1 {
            result = L10n.settingsAutoDownloadsPodcastsSelectedSingular
        } else {
            result = L10n.settingsAutoDownloadsPodcastsSelectedFormat(count.localized())
        }

        return capitalized ? result.localizedCapitalized : result
    }

    static func timeShorthand(_ time: Int) -> String {
        let value = Double(time)
        if value < 60 {
            let components = DateComponents(calendar: .current, second: Int(value))
            return DateComponentsFormatter.localizedString(from: components, unitsStyle: .short) ?? L10n.timePlaceholder
        } else {
            let components = DateComponents(calendar: .current, minute: Int(floor(value / 60.0)), second: Int(value) % 60)
            return DateComponentsFormatter.localizedString(from: components, unitsStyle: .abbreviated) ?? L10n.timePlaceholder
        }
    }

    static func downloadCountPrompt(_ count: Int) -> String {
        count == 1 ? L10n.downloadEpisodeSingular : L10n.downloadEpisodePluralFormat(count.localized())
    }

    static let bulkDownloadMax: String = {
        #if os(watchOS)
            return L10n.bulkDownloadMaxFormat(100.localized())
        #else
            return L10n.bulkDownloadMaxFormat(Constants.Limits.maxBulkDownloads.localized())
        #endif
    }()

    static func seasonEpisodeShorthand(seasonNumber: Int64, episodeNumber: Int64, shortFormat: Bool = false) -> String {
        if seasonNumber > 0, episodeNumber > 0 {
            return L10n.seasonEpisodeShorthandFormat(seasonNumber.localized(), episodeNumber.localized())
        } else if seasonNumber > 0, episodeNumber == 0 {
            return L10n.seasonOnlyShorthandFormat(seasonNumber.localized())
        } else if shortFormat {
            return L10n.episodeShorthandFormatShort(episodeNumber.localized())
        } else {
            return L10n.episodeShorthandFormat(episodeNumber.localized())
        }
    }

    /// `1 bookmark` or `N bookmarks`
    static func bookmarkCount(_ count: Int) -> String {
        count == 1 ? L10n.bookmarksCountSingular : L10n.bookmarksCountPlural(count)
    }
}

extension L10n {
    static func localizedFormat(_ key: String, _ table: String?, _ value: String? = nil) -> String {
        let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)

        if format.isEmpty || format == key {
            // The key hasn't been translated yet so return the english translation
            return BundleToken.baseBundle.localizedString(forKey: key, value: value, table: table)
        }

        return format
    }
}

// swiftlint:disable convenience_type
private final class BundleToken {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
            return Bundle.module
        #else
            return Bundle(for: BundleToken.self)
        #endif
    }()

    static let baseBundle: Bundle = {
        let path = Bundle.main.path(forResource: "en", ofType: "lproj")
        return Bundle(path: path!)!
    }()
}
