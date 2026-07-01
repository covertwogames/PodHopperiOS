import Combine
import PocketCastsServer
import PocketCastsUtils
import SwiftUI

struct SourceRow: View {
    let sourceSymbol: String
    let label: String
    let active: Bool

    var body: some View {
        HStack {
            Text(sourceSymbol)
                .font(.title2)
            Text(label)
            Spacer()
            if active {
                Image("now-playing-small")
            }
        }
    }
}

struct UserRow: View {
    let username: String
    let profileImage: String
    let isLoggedIn: Bool

    var body: some View {
        HStack {
            Image(profileImage)
            VStack(alignment: .leading) {
                if isLoggedIn {
                    Text(L10n.signedInAs)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Text(username)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

struct SourceInterfaceNavigationView: View {

    @State var activeSource: Int? = SourceManager.shared.currentSource().rawValue

    @StateObject var model = SourceInterfaceModel()

    @ViewBuilder
    var sourceSection: some View {
        Section {
            NavigationLink(destination: InterfaceView(source: .phone), tag: Source.phone.rawValue, selection: $activeSource) {
                SourceRow(sourceSymbol: L10n.phone.sourceUnicode(isWatch: false), label: L10n.phone, active: model.activeSource == .phone)
            }
            NavigationLink(destination: InterfaceView(source: .watch), tag: Source.watch.rawValue, selection: $activeSource) {
                SourceRow(sourceSymbol: L10n.watch.sourceUnicode(isWatch: true), label: L10n.watch, active: model.activeSource == .watch)
            }.disabled(!model.isLoggedIn)
        } footer: {
            if model.isLoggedIn {
                Text(L10n.watchSourceMsg)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    var dataRefreshSection: some View {
        if model.isLoggedIn {
            Section {
                Button(action: {
                    model.refreshDataTapped()
                }, label: {
                    MenuRow(label: L10n.watchSourceRefreshData, icon: "retry")
                })
            } footer: {
                Text(model.lastRefreshLabel)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    var userSection: some View {
        Section {
            UserRow(username: model.usernameLabel, profileImage: model.profileImage, isLoggedIn: model.isLoggedIn)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    var accountSection: some View {
        if model.isLoggedIn {
            Section {
                Button(action: {
                    model.logout()
                }, label: {
                    MenuRow(label: "Sign out", icon: "profile-refresh")
                })
            }
        } else {
            Section {
                NavigationLink(destination: WatchPairingView()) {
                    MenuRow(label: "Sign in", icon: "profile-refresh")
                }
            } footer: {
                Text("Sign in to sync your podcasts to this watch and listen without your phone.")
                    .font(.footnote)
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                sourceSection
                dataRefreshSection
                userSection
                accountSection
            }.onAppear {
                model.willActivate()
            }.onChange(of: activeSource) { newValue in
                guard let newValue, let newSource = Source(rawValue: newValue) else {
                    return
                }
                if newSource == .phone {
                    model.phoneTapped()
                } else {
                    model.watchTapped()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(L10n.watchPlaySource)
        }
        .environmentObject(NavigationManager.shared)
    }
}

#Preview {
    SourceInterfaceNavigationView()
}
