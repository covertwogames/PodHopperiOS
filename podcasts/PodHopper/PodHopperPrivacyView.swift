import SwiftUI

/// PodHopper's privacy policy screen. Mirrors the Android PrivacyFragment exactly: a title, the last
/// updated date, an intro, and eight heading/body sections. This replaces the old Pocket Casts
/// analytics opt-out settings screen.
struct PodHopperPrivacyView: View {
    @EnvironmentObject var theme: Theme

    private struct Section {
        let heading: String
        let body: String
    }

    private let intro = "PodHopper is developed by Cover Two Strategies LLC, doing business as Cover Two Games (\"we,\" \"us,\" \"our\"). This policy explains what the app handles and how. It is short on purpose, because the app is built to collect as little as possible."

    private let sections: [Section] = [
        Section(
            heading: "The short version",
            body: "PodHopper does not track you, show ads, run analytics, or sell or share your information with anyone. The only information we handle is what is needed to sync your podcasts between your own devices."
        ),
        Section(
            heading: "Stays on your device",
            body: "Your listening statistics, the charts and totals on your stats page, are calculated and stored locally on your device and used only to display your stats in the app. They are never sent to us or anyone else."
        ),
        Section(
            heading: "Used for syncing",
            body: "If you create an account and sign in, PodHopper stores your podcast subscriptions and listening data, such as which episodes you have played and your progress, so they sync across the devices where you are signed in. That is the only reason this information is collected and the only thing it is used for. It lives on secure cloud infrastructure we use solely to run the sync feature. It is not made available to any third party for any reason: not sold, not rented, not shared for advertising. To sign in, we store the email address tied to your account, used only for authentication and account recovery."
        ),
        Section(
            heading: "What we do not do",
            body: "No advertising or ad tracking. No analytics or usage tracking. No third-party data sharing. No selling your data, ever."
        ),
        Section(
            heading: "Security",
            body: "We take reasonable measures to protect the syncing information. No system is perfectly secure, so we limit what we collect precisely so there is very little to protect."
        ),
        Section(
            heading: "Children",
            body: "PodHopper is not directed at children under 13, and we do not knowingly collect their personal information."
        ),
        Section(
            heading: "Changes",
            body: "If this policy changes, we will update the date above and post the new version in the app."
        ),
        Section(
            heading: "Contact",
            body: "Questions about this policy? Email info@covertwogames.com."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("PodHopper Privacy Policy")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                Text("Last updated: June 24, 2026")
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                Text(intro)
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                ForEach(sections.indices, id: \.self) { index in
                    let section = sections[index]
                    Text(section.heading)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    Text(section.body)
                        .font(.system(size: 17))
                        .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(AppTheme.color(for: .primaryUi02, theme: theme).ignoresSafeArea())
    }
}
