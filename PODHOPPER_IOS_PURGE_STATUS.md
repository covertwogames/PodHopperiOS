# PodHopper iOS: purge status, server independence, and remaining work

State as of July 2026, after purge waves 1-5, the Xcode finale, and the Pocket Casts server
cutover. This is the map for anyone (including a future session) picking the work back up.

## Where things stand

The app is structurally independent of Pocket Casts. Roughly 250 files deleted across five
waves, four third party packages removed, the TV target gone, and every Pocket Casts server
call replaced with local data. The app ships from Xcode, archives, and uploads to App Store
Connect. App Store ID 6786098145, bundle com.covertwogames.podhopper.

## Completed

**Waves 1-2:** telemetry adapters, Sentry surfaces, Sonos, Pocket Casts list sharing,
BackgroundSyncManager, the referrals program, the pca.st shared item import chain.

**Wave 3:** the Ratings cluster, the Kids Profile cluster, the Blaze ad machinery.

**Wave 4:** every End of Year entry point severed (Profile prompt row, MainTab orchestrator,
badges, deep links, AppDelegate hooks) plus its two orphan views.

**Wave 5:** 99 files. All Pocket Casts account screens (sign in, registration, change email
and password), the login coordination layer, the Plus purchase surface, cancel subscription,
supporter and promotion screens, the encourage account modal. OnboardingFlow could not be
deleted (it is referenced by PaidFeature, IAPHelper, the navigation protocol signatures, and
several live views), so its begin() is a husk that returns an empty controller.

**Xcode finale:** removed the four social login files, then the Firebase, Automattic-Tracks,
Sentry, and GoogleSignIn packages from Modules/Package.swift (they were never in the Xcode
project UI), then the Pocket Casts TV App target and its 100 files. Also deleted the ABTest
folder, FirebaseManager, and FileLog+FileUpload (which could upload encrypted user logs to
Automattic during support requests).

**Server cutover:** the last four live Pocket Casts server calls now use local data.
In-podcast episode search filters the local database. Podcast colors read from the local
database. addFromUuid resolves against the local database instead of the cache server. The
OPML export builds its uuid to feed url mapping on device. This section originally said zero
calls to any Pocket Casts network handler remained. That was wrong: two were still live, and
Stage 1 (below) removed them.

**Stage 1 (October 2026):** a full trace of what was left found two live contacts with Pocket
Casts servers and removed both. Suggested folders were fetched in the background on every launch
even though the feature flag is off (FoldersCoordinator now checks the flag, and
ApiServerHandler.suggestedFolders returns nil without a request). Artwork fell back to the Pocket
Casts image server for a podcast with no artwork of its own, and the color tiles for your own
files were downloaded from it (ServerHelper.imageUrl now points at a file that never exists, so
the placeholder shows; userEpisodeDefaultImageUrl draws the color tile on the device and keeps it
in Caches/PodHopperFileArtwork). Also in Stage 1: the EventHorizonSDK binary package (downloaded
from Automattic at build time, never called) removed from Modules/Package.swift; the pktc
/resetalltours and /pair link routes removed; the "..." menu removed from the legal web pages;
the app's network user agent says PodHopper; the lock screen shows PodHopper as the artist for
your own files; the notification and watch no-artwork placeholders, the how-to logo, and the Siri
shortcut icons replaced with PodHopper versions; the watch accent color and complication tint
changed from red to PodHopper green (#269E5F); "Pocket Casts" replaced with PodHopper in the
translated strings (de, fr, fr-CA, ja, nl, pt-BR, ru, sv); AutomatticTracksiOS and Firebase
removed from the acknowledgements page, since neither is in the app any more.

**Link type (October 2026):** the app registers podhopper:// instead of pktc://, the old app's
link type, so other apps and websites can no longer open PodHopper with pktc links, and links the
app sends itself (the share extension, the Settings link in the Not on Wi-Fi warning) can no
longer land in Pocket Casts when both apps are installed. Every link the app builds (widgets,
share extension, home screen quick actions, Siri, local notifications, in-app links) uses
podhopper://. AppDelegate+UrlHandling still accepts pktc links that reach it directly (a widget
placed before the update, until widgets refresh), see appLinkSchemes. Routing (JLRoutes) never
depended on the link type. Left alone on purpose: the internal au.com.shiftyjelly identifiers.
The KeychainHelper prefix holds the PodHopper sign-in, so renaming it signs everyone out. The
background download and upload session ids would orphan transfers in progress at update time.
The background refresh task id, the Siri activity type, and the quick action type are invisible,
so renaming them only adds risk.

## Current architecture

Refresh, discovery, search, and subscriptions all run on PodHopper's own layer in
Modules/Sources/PocketCastsServer/PodHopper (feed manager, feed parser, RSS refresh, iTunes
search, iTunes top list loader, Supabase client, subscription and position sync). Auth is
PodHopper's own Supabase backed flow (PodHopperAuthView). Episode notifications are generated
locally on device; the app no longer registers for remote push at all.

## End of Year: refactor, not purge

The EOY trees are NOT deletable. The onboarding intro carousel, login cover art, WhatsNew
views, and ServerPodcastManager are built on the EOY stories engine and its shared components
(dependency closure: 55 of 58 app files load-bearing). All entry points are severed and the
code is unreachable, but it is load-bearing at compile time. Deleting it means first
extracting the stories engine and shared views. Note: wave 5 killed the intro carousel and
interests views, so this may now be easier than it was; recompute the closure before starting.

## Watch item: mark-as-played ordering (no action taken)

Android had a bug where marking the currently playing episode as played corrupted the Up Next
queue and froze the player, because the queue advanced before the completed status was written.
iOS has the same ordering (EpisodeManager.markAsPlayed calls
PlaybackManager.removeIfPlayingOrQueued, which synchronously advances playback, before writing
playingStatus = completed), but a full trace found no actual defect:

- The two writes are column scoped (playingStatus vs playedUpTo), so neither can clobber the other.
- Nothing in the advance path reads the outgoing episode's status. playNextEpisode reads the next
  episode's status only, and Up Next stores uuids.
- PodHopperPositionSync uses a serial queue and pushCompletion is enqueued last, so no cross-device
  desync. Both pushCompletion callers already push after the local write.
- Notifications post synchronously on the main thread, so observers can transiently read the stale
  status, but markAsPlayed then writes completed and fires episodePlayStatusChanged, so the UI
  settles correct.

If a related bug does surface (playback stopping or an episode appearing unplayed after being
marked played), the fix is to write the completed status before calling removeIfPlayingOrQueued.
The trap when doing that: autoplayIfNeeded resolves the next episode via
AutoplayHelper.nextEpisode, which locates the CURRENT episode by index in its source list. Podcast
lists do not filter on playing status, but smart filters do (PlaylistQueryBuilder), and a filter
that excludes finished episodes would drop the episode as soon as it is marked completed, so
firstIndex would fail and autoplay would stop. The query pins the playing episode
(episodeUuidToAddToQueries) only when PlaybackManager.uuidOfPlayingList matches that filter. So any
reorder must resolve the autoplay next-episode decision before the status write, not rely on the
pin. bulkMarkAsPlayed routes the current episode through markAsPlayed, so it inherits any fix.

## Remaining cleanup (none urgent, nothing user facing)

- **Leftovers of the legal web view menu.** Stage 1 removed the line that created the "..." menu
  (Connection Status, Export Database, Logs) in OnlineSupportController. An earlier version of
  this note said the menu never rendered; that was not certain, because the customRightBtn setter
  in PCViewController does put the button on the navigation item, and the controller is shown
  inside SwiftUI. Either way it is gone now. Its private functions (makeOptionsMenu,
  showStatusPage, export, viewLogs) and the screens only it opened (LogsView, LogsViewController,
  StatusPageView, StatusPageViewModel) are now dead code. Delete them together.
- **Zendesk.** ZendeskSupportService and the message support stack have no reachable presenter
  (EmailHelper, their only caller, has zero callers). Deletable.
- **Vestigial Pocket Casts constants.** The service host functions in ServerConstants (main,
  api, cache, discover, image, files, share, lists, search, generatedTranscripts) now have no
  live callers. The Fingerprint subsystem also has no reachable trigger.
- **addFromiTunesId** still points at the Pocket Casts server, but no live flow reaches it
  (Discover resolves iTunes entries to feed urls before opening a podcast page). Dead by flow,
  not by code.
- **Unit test target does not build.** PocketCastsTests/Tests/ABTest/ABTestProviderTests.swift
  still imports AutomatticTracks, which the Xcode finale removed. The app itself is not affected;
  only running the unit tests is. Delete that test file (it tests the removed ABTest code).
- **Developer-only leftovers with pktc links.** scripts/notifications/*.apns (simulator push
  payloads for the old app's bundle id; PodHopper does not register for remote push) and
  Screenshot Automation/GenerateScreenshots.swift (a UI test pointing at a share-list route that
  no longer exists). Not shipped. Delete with the other unused files.
- **Unused leftovers.** The "Pocketcasts.com" string in every language
  (plus_subscription_web_details) and the about_a8c_family string have no callers. ServerHelper's
  colorUrl, playerUrl, and bundleUrl still name Pocket Casts addresses but have no live callers.
- **Deferred product items:** CarPlay entitlement request and real car validation, reviewer
  account for App Store review, the 8.15 vs 1.0 version decision, watch standalone gating.

## Process rules (each one was paid for in a broken build)

1. **Never use the pbxproj python library's save() on this project.** It quotes the custom
   non-hex ListeningHeatmap ids (breaking their target membership) and strips synchronized
   folder lines. Text anchored line surgery only, with enumerated expected removal counts.
2. **Check registration before deleting.** Grep the pbxproj for the filename. Registered files
   need their PBXBuildFile, PBXFileReference, group child, and build phase lines removed. Watch
   for sibling .xcassets catalogs registered separately (Referrals and KidsProfile both had one).
3. **Extraction must include extension members**, not just declared types. Files whose only
   exports are extensions on live types (Theme+Plus, the IAPProductID attributes) are invisible
   to a type-only scan and will break the build. Same for static constants.
4. **Verify every member match at its declaration.** Sampling hits is how product(for:) got
   missed. Generic names need per-hit inspection, not pattern exclusion.
5. **Relocated code carries its donor's imports.** Moving an extension into a new file means
   checking every identifier it uses resolves against the destination's imports.
6. **Removing a package strands its transitive imports.** After removing an SPM package, audit
   every import statement in the repo against what modules still exist (UIDeviceIdentifier came
   in through Automattic-Tracks), and expect code that silently compiled against ObjC categories
   in those packages to break (FileManager.fileExistsAtURL came from Sentry).
7. **Compute the dependency closure before committing to a deletion scope.** EOY looked
   deletable and was not.
8. **"The code exists" is not "the user can reach it."** Every claim about runtime behavior must
   be traced to an actual UI trigger or lifecycle event, not inferred from a grep hit. Three
   separate wrong findings in the server audit came from skipping this. Trace sinks upward to a
   real entry point, and prefer testing the app over reading the code.
