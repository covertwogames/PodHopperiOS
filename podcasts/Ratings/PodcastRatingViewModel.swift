import SwiftUI
import PocketCastsServer
import PocketCastsDataModel
import PocketCastsUtils

class PodcastRatingViewModel: ObservableObject {
    @Published var rating: PodcastRating? = nil
    @Published var presentingGiveRatings = false

    var presentLogin: ((PodcastRatingViewModel) -> Void)? = nil

    /// Whether we should display the total ratings or not
    var showTotal: Bool = true

    var hasRatings: Bool {
        guard let rating else {
            return false
        }
        return rating.total > 0
    }

    private var state: LoadingState = .waiting

    /// Internally track the podcast UUID
    /// We don't init with this because the podcast view controller may not have
    /// the uuid yet
    private(set) var uuid: String? = nil

    private(set) var podcast: Podcast?

    /// Updates the rating for the podcast.
    ///
    func update(podcast: Podcast?, ignoringCache: Bool = false) {
        // PodHopper: podcast ratings are a Pocket Casts service. The rating UI is removed and
        // this never fetches, so any leftover surface simply renders without a rating.
        self.podcast = podcast
    }

    private enum LoadingState {
        case waiting, loading, done
    }

    enum RatingSource: String {
        case button
        case stars
    }
}

// MARK: - View Interactions
extension PodcastRatingViewModel {
    func didTapRating(source: RatingSource = .button) {
        Analytics.track(.ratingStarsTapped, properties: [
            "uuid": uuid ?? "unknown",
            "source": source.rawValue
        ])
        if SyncManager.isUserLoggedIn() {
            presentingGiveRatings = true
        } else {
            DispatchQueue.main.async {
                self.presentLogin?(self)
            }
        }
    }
}
