import SwiftUI

// PodHopper: the stories this flag was made for are gone. PodcastCover still declares it and
// SlumberViews still sets it, so the key stays here, unchanged, so both keep compiling.
extension EnvironmentValues {
    public var renderForSharing: Bool {
        get { self[RenderSharingKey.self] }
        set { self[RenderSharingKey.self] = newValue }
    }

    private struct RenderSharingKey: EnvironmentKey {
        static let defaultValue: Bool = false
    }
}
