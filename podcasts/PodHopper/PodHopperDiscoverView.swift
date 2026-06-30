import Kingfisher
import PocketCastsServer
import SwiftUI

enum PodHopperDiscoverMode {
    case landing
    case fullGrid
}

/// PodHopper's Discover screen. Mirrors the Android Add Podcast page: a landing with a search bar, a
/// suggestions grid from the iTunes top list, a Discover more link to the full grid, and an add by
/// RSS url row; and a full grid mode that shows the larger grid on its own pushed screen. All actions
/// are driven through the view model so the hosting controller owns the UIKit navigation.
struct PodHopperDiscoverView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var viewModel: PodHopperDiscoverViewModel
    let mode: PodHopperDiscoverMode

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    var body: some View {
        ZStack {
            AppTheme.color(for: .primaryUi01, theme: theme).ignoresSafeArea()
            switch mode {
            case .landing:
                landing
            case .fullGrid:
                fullGrid
            }
        }
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Add podcast")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                content
                    .padding(.top, 16)
                discoverMoreRow
                    .padding(.top, 8)
                addByUrlRow
            }
            .padding(.bottom, 24)
        }
    }

    private var fullGrid: some View {
        ScrollView {
            content
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case .error:
            errorView
        case .loaded(let podcasts):
            grid(podcasts)
        }
    }

    private func grid(_ podcasts: [PodHopperTopListLoader.TopPodcast]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 8) {
            ForEach(podcasts, id: \.itunesId) { item in
                tile(item)
            }
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ item: PodHopperTopListLoader.TopPodcast) -> some View {
        Button {
            viewModel.tileTapped(item)
        } label: {
            KFImage(item.imageUrl.flatMap(URL.init(string:)))
                .placeholder { _ in
                    AppTheme.color(for: .primaryUi05, theme: theme)
                }
                .resizable()
                .fade(duration: 0.2)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        Button {
            viewModel.onSearchBarTap?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                Text("Search podcast...")
                    .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(AppTheme.color(for: .primaryUi02, theme: theme))
            )
        }
        .buttonStyle(.plain)
    }

    private var discoverMoreRow: some View {
        HStack {
            Text("Popular podcasts")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.color(for: .primaryText02, theme: theme))
            Spacer()
            Button {
                viewModel.onDiscoverMore?()
            } label: {
                Text("Discover more")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var addByUrlRow: some View {
        Button {
            viewModel.onAddByUrl?()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                Text("Add podcast by RSS address")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Text("Podcasts could not be loaded.")
                .font(.system(size: 15))
                .foregroundColor(AppTheme.color(for: .primaryText01, theme: theme))
                .multilineTextAlignment(.center)
            Button {
                viewModel.retry()
            } label: {
                Text("Retry")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.color(for: .primaryInteractive01, theme: theme))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}
