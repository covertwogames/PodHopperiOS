import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils

/// PodHopper: episode information comes straight from the local database instead of the
/// Pocket Casts cache server. Show notes are the episode description parsed from the RSS
/// feed, artwork falls back to the podcast artwork, chapters come from the embedded chapter
/// parser during playback, and there are no remote transcripts.
actor ShowInfoCoordinator: ShowInfoCoordinating {
    static let shared = ShowInfoCoordinator()

    private let dataManager: DataManager

    init(dataManager: DataManager = .sharedManager) {
        self.dataManager = dataManager
    }

    func loadShowNotes(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> String {
        if let notes = dataManager.findEpisode(uuid: episodeUuid)?.episodeDescription, notes.isEmpty == false {
            return notes
        }

        return CacheServerHandler.noShowNotesMessage
    }

    func loadEpisodeArtworkUrl(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> String? {
        nil
    }

    public func loadChapters(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> ([Episode.Metadata.EpisodeChapter]?, [PodcastIndexChapter]?) {
        (nil, nil)
    }

    public func loadTranscriptsMetadata(
        podcastUuid: String,
        episodeUuid: String
    ) async throws -> EpisodeTranscriptData {
        (transcripts: [], hasGeneratedTranscripts: false, isDisplayingGeneratedTranscript: false)
    }
}
