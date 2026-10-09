import Foundation

extension ApiServerHandler {
    /// PodHopper: folder suggestions came from a server that has no knowledge of PodHopper's
    /// podcasts. The feature is switched off in FeatureFlag, and this returns nothing so that no
    /// request is ever made even if the flag is turned back on.
    public func suggestedFolders(for uuids: [String], language: String = Locale.current.language.languageCode?.identifier ?? "en") async -> SuggestedFoldersResponse? {
        nil
    }
}
