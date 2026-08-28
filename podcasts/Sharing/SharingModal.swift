import PocketCastsDataModel
import SwiftUI
import PocketCastsUtils
import EndOfYear

enum SharingModal {

    /// Share options including which type of content will be shared
    enum Option {
        case episode(Episode)
        case podcast(Podcast)
        case currentPosition(Episode, TimeInterval)
        case bookmark(Episode, TimeInterval)

        var buttonTitle: String {
            switch self {
            case .episode:
                L10n.episode
            case .currentPosition, .bookmark:
                L10n.shareCurrentPosition
            case .podcast:
                L10n.podcastSingular
            }
        }

        static func allCases(episode: Episode?, podcast: Podcast, currentTime: TimeInterval) -> [Option] {
            if let episode {
                [
                    .episode(episode),
                    .podcast(podcast),
                    .currentPosition(episode, currentTime)
                ]
            } else {
                [
                    .podcast(podcast)
                ]
            }
        }
    }

    static func showModal(episode: Episode, from source: AnalyticsSource, in viewController: UIViewController) {
        guard let podcast = episode.parentPodcast() else {
            assertionFailure("Podcast should exist for episode")
            return
        }
        showModal(podcast: podcast, episode: episode, from: source, in: viewController)
    }

    static func showModal(podcast: Podcast, episode: Episode?, from source: AnalyticsSource, in viewController: UIViewController) {

        if podcast.isPrivate {
            Toast.show(L10n.sharePodcastPrivateNotAvailable)
            return
        }

        let colors = OptionsPickerRootController.Colors(title: UIColor.white.withAlphaComponent(0.5), background: PlayerColorHelper.playerBackgroundColor01())

        let optionPicker = OptionsPicker(title: L10n.share.uppercased(), themeOverride: .dark, colors: colors)

        let timeInterval: Double
        if PlaybackManager.shared.currentEpisode()?.uuid == episode?.uuid {
            timeInterval = PlaybackManager.shared.currentTime()
        } else {
            timeInterval = episode?.playedUpTo ?? 0
        }

        let actions: [OptionAction] = Option.allCases(episode: episode, podcast: podcast, currentTime: timeInterval).map { option in
                .init(label: option.buttonTitle, action: {
                    show(option: option, from: source, in: viewController)
            })
        }
        optionPicker.addActions(actions)

        if let vc = (viewController as? EpisodeDetailViewController),
           let fileAction = vc.episodeFileAction(from: .zero) {
            optionPicker.addAction(action: fileAction)
        }

        optionPicker.present(from: viewController)
    }

    static func show(option: Option, from source: AnalyticsSource, in viewController: UIViewController) {

        if option.podcast.isPrivate {
            Toast.show(L10n.sharePodcastPrivateNotAvailable)
            return
        }

        // PodHopper: plain text share matching the Android app. A podcast shares its feed URL; an
        // episode shares its media URL plus the feed URL to subscribe. The Pocket Casts styled
        // card and clip flow is gone along with its pca.st links.
        let podcast = option.podcast
        let feedUrl = podcast.podcastUrl?.trim() ?? ""
        var text: String
        switch option {
        case .podcast:
            text = "Check out \(podcast.title ?? "this podcast")"
            if feedUrl.isEmpty == false {
                text += ": \(feedUrl)"
            }
        case .episode(let episode), .currentPosition(let episode, _), .bookmark(let episode, _):
            text = "Listen to \(episode.title ?? "this episode") from \(podcast.title ?? "this podcast")"
            if let mediaUrl = episode.downloadUrl, mediaUrl.isEmpty == false {
                text += ": \(mediaUrl)"
            }
            if feedUrl.isEmpty == false {
                text += "\n\nSubscribe to their show at: \(feedUrl)"
            }
        }

        let activityController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activityController.popoverPresentationController?.sourceView = viewController.view
        activityController.popoverPresentationController?.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 44, height: 44)
        viewController.present(activityController, animated: true)
    }
}

extension SharingModal.Option {

    /// The podcast behind whichever option was chosen. Used by the share text builder above.
    fileprivate var podcast: Podcast {
        switch self {
        case .episode(let episode), .currentPosition(let episode, _), .bookmark(let episode, _):
            return episode.parentPodcast()!
        case .podcast(let podcast):
            return podcast
        }
    }
}
