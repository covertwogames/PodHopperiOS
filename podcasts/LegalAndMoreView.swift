import SwiftUI

struct LegalAndMore: View {
    @EnvironmentObject var theme: Theme

    @State private var showTermsOfService = false
    @State private var showPrivacyPolicy = false
    @State private var showAcknowledgements = false

    var body: some View {
        ZStack {
            ThemeColor.primaryUi04(for: theme.activeTheme).color
                .ignoresSafeArea()
            List {
                Section {
                    AboutRow(mainText: L10n.aboutTermsOfService, showChevronIcon: true) {
                        track(row: "terms_of_service")
                        showTermsOfService = true
                    }
                    AboutRow(mainText: L10n.aboutPrivacyPolicy, showChevronIcon: true) {
                        track(row: "privacy_policy")
                        showPrivacyPolicy = true
                    }
                    AboutRow(mainText: L10n.aboutAcknowledgements, showChevronIcon: true) {
                        track(row: "acknowledgements")
                        showAcknowledgements = true
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationBarTitle(L10n.aboutLegalAndMore, displayMode: .inline)
        // Terms of Service
        NavigationLink(
            destination: WebView(url: Constants.termsOfUseURL).navigationTitle(L10n.aboutTermsOfService),
            isActive: $showTermsOfService
        ) {}
        // Privacy Policy
        NavigationLink(
            destination: WebView(url: Constants.privacyPolicyURL).navigationTitle(L10n.aboutPrivacyPolicy),
            isActive: $showPrivacyPolicy
        ) {}
        // Acknowledgements
        NavigationLink(
            destination: WebView(url: Constants.acknowledgementsURL).navigationTitle(L10n.aboutAcknowledgements),
            isActive: $showAcknowledgements
        ) {}
    }

    private func track(row: String) {
        Analytics.track(.settingsAboutLegalAndMoreTapped, properties: ["row": row])
    }

    private enum Constants {
        // PodHopper: each row opens its own page. Both used to open the same older privacy page.
        static let termsOfUseURL = PodHopperTerms.termsURL
        static let privacyPolicyURL = PodHopperTerms.privacyURL
        static let acknowledgementsURL = Bundle.main.url(forResource: "acknowledgements", withExtension: "html")!
    }
}

private struct WebView: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> OnlineSupportController {
        OnlineSupportController(url: url, source: .about)
    }

    func updateUIViewController(_ uiViewController: OnlineSupportController, context: Context) {}
}
