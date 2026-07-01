import Foundation
import PocketCastsServer
import StoreKit
import UIKit

/// Requests an App Store rating based purely on total listening time, mirroring the Android
/// AppReviewManager: the first prompt once total listening reaches three hours, a second at twenty
/// hours, and never more than twice. iOS decides whether to actually show the rating card and will
/// not re-prompt someone who has already rated. This replaces the old "Are you enjoying?" survey.
final class PodHopperReviewManager {
    static let shared = PodHopperReviewManager()

    private let maxPrompts = 2
    private let firstThresholdSeconds: TimeInterval = 3 * 60 * 60
    private let secondThresholdSeconds: TimeInterval = 20 * 60 * 60
    private let promptDelaySeconds: TimeInterval = 2
    private let promptCountKey = "podhopperReviewPromptCount"

    private var promptCount: Int {
        get { UserDefaults.standard.integer(forKey: promptCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptCountKey) }
    }

    /// Checks the listening-time thresholds and, when the next one is crossed, asks iOS to show its
    /// rating prompt after a short delay so it does not interrupt the moment the app opens. Call when
    /// the app becomes active.
    func requestReviewIfEligible() {
        let count = promptCount
        if count >= maxPrompts {
            return
        }

        let threshold = count == 0 ? firstThresholdSeconds : secondThresholdSeconds
        if StatsManager.shared.totalListeningTime() < threshold {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + promptDelaySeconds) { [weak self] in
            guard let self else { return }
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
                return
            }

            AppStore.requestReview(in: scene)
            self.promptCount = count + 1
            // Record it with the shared review bookkeeping so other legacy prompts stay silent.
            Settings.addReviewRequested()
            Analytics.track(.appStoreReviewRequested, properties: ["source": "podhopper_listening_time"])
        }
    }
}
