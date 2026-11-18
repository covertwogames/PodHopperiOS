import SwiftUI

/// PodHopper's privacy policy screen, reached from Settings. It shows the policy word for word as
/// published at podhopper.app/privacy; the text itself lives in PodHopperPrivacyText. The copy built
/// into the app only changes when the app is updated, so the screen says where the current version
/// always is.
struct PodHopperPrivacyView: View {
    @EnvironmentObject var theme: Theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(PodHopperPrivacyText.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))

                Text("Last updated: " + PodHopperPrivacyText.lastUpdated)
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                    .padding(.top, 4)

                Text("The current version is always at podhopper.app/privacy")
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, 16)

                ForEach(PodHopperPrivacyText.intro.indices, id: \.self) { index in
                    PodHopperPrivacyLine(markdown: PodHopperPrivacyText.intro[index], style: .primaryText01)
                        .padding(.bottom, 8)
                }

                ForEach(PodHopperPrivacyText.sections.indices, id: \.self) { index in
                    PodHopperPrivacySectionView(section: PodHopperPrivacyText.sections[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(AppTheme.color(for: .primaryUi02, theme: theme).ignoresSafeArea())
    }
}

/// One numbered section: its heading, then its paragraphs and bullets in order.
private struct PodHopperPrivacySectionView: View {
    @EnvironmentObject var theme: Theme
    let section: PodHopperPrivacyText.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.heading)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(section.blocks.indices, id: \.self) { index in
                PodHopperPrivacyBlockView(block: section.blocks[index])
            }
        }
    }
}

/// A paragraph, or a bullet with its dot.
private struct PodHopperPrivacyBlockView: View {
    @EnvironmentObject var theme: Theme
    let block: PodHopperPrivacyText.Block

    var body: some View {
        switch block {
        case .paragraph(let markdown):
            PodHopperPrivacyLine(markdown: markdown)
                .padding(.bottom, 10)
        case .bullet(let markdown):
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: "\u{2022}")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                PodHopperPrivacyLine(markdown: markdown)
            }
            .padding(.leading, 8)
            .padding(.bottom, 8)
        }
    }
}

/// The words of one paragraph or bullet, with bold lead-ins and tappable links.
private struct PodHopperPrivacyLine: View {
    @EnvironmentObject var theme: Theme
    let markdown: String
    var style: ThemeStyle = .primaryText02

    var body: some View {
        Text(PodHopperMarkdown.attributed(markdown, linkColor: AppTheme.color(for: .primaryInteractive01, theme: theme)))
            .font(.system(size: 17))
            .foregroundColor(AppTheme.color(for: style, theme: theme))
            .fixedSize(horizontal: false, vertical: true)
    }
}
