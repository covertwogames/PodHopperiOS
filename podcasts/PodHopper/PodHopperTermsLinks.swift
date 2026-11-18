import SwiftUI

/// PodHopper: the wording around agreeing to the Terms of Service and Privacy Policy, shared by the
/// create account, log in, first-run and one-time Terms screens. The same sentences the Android app
/// uses.
///
/// The sentences that carry links are written in Markdown, with the two names as [text](address)
/// links. `PodHopperTermsLinksText` shows them with those names tappable.
enum PodHopperTermsCopy {
    private static let links = "[Terms of Service](" + PodHopperTerms.termsAddress + ") and [Privacy Policy](" + PodHopperTerms.privacyAddress + ")"

    /// Create account. The box must be ticked before an account is created.
    static let checkbox = "I agree to the " + links
    static let checkboxSpoken = "I agree to the Terms of Service and Privacy Policy"
    static let checkboxRequired = "Please agree to the Terms of Service and Privacy Policy to create an account"

    /// Log in, and continue without an account.
    static let loginNotice = "By logging in you agree to the " + links + "."
    static let continueNotice = "By continuing you agree to the " + links + "."
    static let continueNoticePlain = "By continuing you agree to the Terms of Service and Privacy Policy."

    /// The one-time screen shown to people who were already using PodHopper before the Terms existed.
    static let promptTitle = "PodHopper now has Terms of Service"
    static let promptMessage = "Please take a moment to read them, along with our Privacy Policy. They cover how PodHopper works, your account, and using PodHopper in a vehicle."
    static let promptReadTerms = "Read the Terms of Service"
    static let promptReadPrivacy = "Read the Privacy Policy"
    static let promptAgree = "Agree and continue"
    static let promptFooter = "By tapping Agree and continue you agree to the " + links + "."
}

/// PodHopper: turns one line written in Markdown, with **bold** words and [text](address) links,
/// into styled text a SwiftUI `Text` can show. The links are tappable and drawn in `linkColor`.
enum PodHopperMarkdown {
    static func attributed(_ markdown: String, linkColor: Color) -> AttributedString {
        var attributed = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = linkColor
        }
        return attributed
    }
}

/// PodHopper: a sentence in which the words "Terms of Service" and "Privacy Policy" are links that
/// open those pages in the browser. Pass one of the Markdown sentences from `PodHopperTermsCopy`.
struct PodHopperTermsLinksText: View {
    @EnvironmentObject var theme: Theme

    private let markdown: String
    private let alignment: TextAlignment

    init(_ markdown: String, alignment: TextAlignment = .center) {
        self.markdown = markdown
        self.alignment = alignment
    }

    var body: some View {
        Text(PodHopperMarkdown.attributed(markdown, linkColor: AppTheme.color(for: .primaryInteractive01, theme: theme)))
            .font(.system(size: 14))
            .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
