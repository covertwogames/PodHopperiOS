import Foundation
import PocketCastsDataModel

extension PodcastViewController {
    func performEpisodeSearch(query: String) {
        guard let podcast else { return }

        // PodHopper: episodes are searched on device against the local database instead of the
        // Pocket Casts episode search server, which cannot resolve PodHopper's feed derived uuids.
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard term.isEmpty == false else {
            showSearchResults(nil)
            return
        }

        let matches = DataManager.sharedManager.allEpisodesForPodcast(id: podcast.id).filter { episode in
            if episode.title?.lowercased().contains(term) == true { return true }
            return episode.episodeDescription?.lowercased().contains(term) == true
        }

        showSearchResults(matches.map { $0.uuid })
    }

    private func showSearchLoading() {}

    func showSearchResults(_ uuids: [String]?) {
        searchController?.searchDidComplete()

        guard let podcast, let uuids else { return }

        uuidsThatMatchSearch = uuids

        loadLocalEpisodes(podcast: podcast, animated: true)
    }
}
