import Foundation

extension NSNotification.Name {
    /// When a user has signed in, signed out, or been signed in during account creation
    static let userLoginDidChange = NSNotification.Name("User.LoginChanged")

    /// When a user logs via login or account creation
    static let userSignedIn = NSNotification.Name("User.SignedOrCreatedAccount")

    /// When the updated onboarding flow dismisses
    static let onboardingFlowDidDismiss = NSNotification.Name("Onboarding.didDismiss")

    /// When the episode artwork is loaded
    static let episodeEmbeddedArtworkLoaded = NSNotification.Name(rawValue: "PCEpisodeEmbeddedArtworkLoaded")

    static let tableViewReorderWillBegin = NSNotification.Name("TableView.ReorderWillBegin")
    static let tableViewReorderDidEnd = NSNotification.Name("TableView.ReorderDidEnd")

    static let whatsNewDismissed = NSNotification.Name("WhatsNew.Dismissed")
}
