# PodHopper iOS: purge status, server independence, and remaining work

State as of October 2026, after purge waves 1-5, the Xcode finale, the Pocket Casts server
cutover, Stage 1, the link type switch, the End of Year removal, and the leftovers stage. This is the map for anyone (including a future session) picking the work back up.

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

**Leftovers (October 2026):** a full trace for unused code, images, strings and libraries,
checked a second time by an independent review. Removed:

- 73 Swift files nothing used, found by a reachability trace (types, extension members, IB
  classes, plist and string literal roots) and vetted file by file. They include the Patron,
  Champion and sign-out leftovers, the referral, rating, winback, feedback and promo code server
  tasks, the TV app's HTML description converter, and the End of Year data layer
  (EndOfYearDataManager, RatingsDataManager, UserPodcastRating, SyncYearListeningHistoryTask, the
  DataManager End of Year methods and its ratings property).
- The support screen leftovers: OnlineSupportController's private menu functions and the screens
  only they opened (LogsView, LogsViewController, StatusPageView, StatusPageViewModel,
  DatabaseExport), and the Zendesk support form (EmailHelper, SupportConfig,
  PCMessageSupportViewModel, the Zendesk folder except ActivityDialog, which the multi-select
  footer uses) with the hand-written support strings in Strings+L10n. The one remaining caller was
  the "Not really" answer of the satisfaction survey, which is switched off by its feature flag
  and reachable only from the developer menu; that answer now only records the response. Also the
  OnlineSupportController rule that rewrote support.pocketcasts.com links.
- The version 7.20 What's New page (aboutWhatsNew.json, WhatsNewHelper, WhatsNewStructs,
  WhatsNewViewController, WhatsNewPageView, WhatsNewThemeableImageView, WhatsNewLinkButton,
  WhatsNewDetailViewController, their xibs, 21 images). Every PodHopper install marked it as seen
  on first launch, so it never showed. The newer announcement views in podcasts/Whats New stay.
- 12 hidden Pocket Casts alternate app icons (Plus, Patron x4, Classic, Electric Blue, Electric
  Pink, Radioactive, Halloween, Red Velvet, Pride): their PNGs, their AlternateAppIcons previews,
  their Info.plist entries, and their IconType cases. The picker only offered the seven PodHopper
  icons. Info.plist also listed the Pride files as the primary icon (inherited from Pocket Casts,
  including a 1024 file that never existed); that list is gone, because the asset catalog
  AppIcon supplies the primary icon at build time.
- 277 unused images (the What's New ones above included), the three catalogs they emptied (Sharing, Sonos, ThreeDeeTouch), the Lottie
  files effects_button, player_play_white_button and skip, the Pocket Casts push sound pc.aiff,
  the Patron haptics (Slam.ahap, Spring.ahap) and EmptyHeaderView.xib.
- 775 unused keys from English and all 14 translations, 3 translation-only keys, and the second
  copy of 7 keys that appeared twice in English with the same text.
- SwiftSoup (its only user was the HTML converter), the App Clip and TV app products and empty
  targets in Modules/Package.swift, and the App Clip and TV app schemes.
- Stale project entries: CancelSubscription.xcassets and the synchronized groups for the deleted
  Ratings, Sonos and ABTest folders.
- Dead constants: the End of Year and What's New settings and keys, the support request defaults
  keys, NavigationProtocol's showWhatsNew and showEndOfYearStories, and the @pocketcasts and
  pocketcasts.com L10n constants.
- PocketCastsTests/Tests/ABTest/ABTestProviderTests.swift, which imported the removed
  AutomatticTracks and stopped the unit test target from compiling. Other stale tests may remain;
  the test target has not been built since.

## Current architecture

Refresh, discovery, search, and subscriptions all run on PodHopper's own layer in
Modules/Sources/PocketCastsServer/PodHopper (feed manager, feed parser, RSS refresh, iTunes
search, iTunes top list loader, Supabase client, subscription and position sync). Auth is
PodHopper's own Supabase backed flow (PodHopperAuthView). Episode notifications are generated
locally on device; the app no longer registers for remote push at all.

## End of Year: removed (October 2026)

An earlier version of this note said the End of Year code could not be deleted because other
screens were built on it. That stopped being true once wave 5 and the PodHopper onboarding
replaced those screens. A fresh closure (two independent traces at 1a1dad141) found End of Year
unreachable in every build (its three feature flags default to false, only the DEBUG beta menu
can change them, and nothing outside its own files presents it), and only four pieces used
anywhere else:

- BottomSheetSwiftUIWrapper (MDCSwiftUIWrapper.swift) and PodcastCover / NormalCoverShadow /
  BigCoverShadow (PodcastCover.swift) were moved unchanged into podcasts/Common SwiftUI. They
  serve the free-up-space sheet, the playlist episode-unavailable alert, the Podroll info sheet,
  the stats info sheet, Settings > Folders History, and folder results in search.
- The EndOfYear Swift package now holds only shared helpers: View.snapshot (CarPlay Filters tab
  artwork; ShareProfileViewModel also calls it without importing the module, which Swift 5
  allows) and the renderForSharing environment key (RenderForSharing.swift; PodcastCover and
  SlumberViews still reference it). CircularProgressView went in the leftovers stage. The package
  keeps the name EndOfYear so Package.swift and the nine `import EndOfYear` lines stay as they
  were. Do not copy those helpers into the app while the package exists: Swift would report
  ambiguous uses everywhere.

Removed: the 54 story files in podcasts/End of Year (and its synchronized group), 10 package
files, EndOfYear.xcassets, 19 Lottie files, 2 mp4s and img_0.png (used only inside the 2025
animations), the DMSans, Humane and Inter fonts with their UIAppFonts entries, the End of Year
tests and EndOfYearManagerMock, and a badge check in PodcastListViewController's uncalled
makeProfileButton. The leftovers stage then removed the End of Year data layer, settings keys,
navigation keys and stub, eoyRegistrationNotRequired, and the unused End of Year strings. Still
there, dead but compiling: the End of Year feature flags and analytics event cases
(UserSatisfactionSurveyManager still uses three of the events), OnboardingFlow's endOfYear cases,
and OnboardingModalHostingViewController.

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

- **Vestigial Pocket Casts constants.** The service host functions in ServerConstants (main,
  api, cache, discover, image, files, share, lists, search) now have no live callers.
  generatedTranscripts is still read by FingerprintReferenceRetriever.
- **Fingerprint (transcript timing sync).** podcasts/Fingerprint (6 files, plus its tests) and
  Automattic's pocket-casts-ios-fingerprint package. TranscriptViewController still calls it, but
  it only runs for Pocket Casts' auto-generated transcripts, which PodHopper can never receive, so
  it never does anything. Removing it means editing TranscriptViewController.
- **Transcripts never appear (feature gap, not cleanup).** ShowInfoCoordinator.loadTranscriptsMetadata
  always returns an empty list, because the list used to come from the Pocket Casts server. The
  feed parser does not read podcast:transcript tags. Fixing this means saving those links per
  episode and returning them there; the transcript screen already loads and shows the files.
- **Bigger code-edit leftovers (deferred, Android skipped this tier too).** Share Profile (debug
  flag), SlumberViews and the announcement screens, the old DiscoverCollectionViewController
  screens, the OnboardingFlow and upsell husks, the user satisfaction survey (flag off), and the
  AppTheme image-name helpers that only those use.
- **addFromiTunesId** still points at the Pocket Casts server, but no live flow reaches it
  (Discover resolves iTunes entries to feed urls before opening a podcast page). Dead by flow,
  not by code.
- **Developer-only leftovers with pktc links.** scripts/notifications/*.apns (simulator push
  payloads for the old app's bundle id; PodHopper does not register for remote push) and
  Screenshot Automation/GenerateScreenshots.swift (a UI test pointing at a share-list route that
  no longer exists). Not shipped.
- **Developer-only App Clip and TV leftovers.** The tvOS lanes in fastlane/Fastfile, the tvOS
  group in .buildkite/pipeline.yml, an empty "Embed App Clips" copy phase in the podcasts target,
  and a missing ServerTests target listed in the NotificationContent, NotificationExtension and
  PodcastsIntents schemes. None of it is built into the app.
- **Unused leftovers.** ServerHelper's colorUrl, playerUrl, and bundleUrl still name Pocket Casts
  addresses but have no live callers. ServerCredentials.sharing is set at launch but nothing reads
  it any more, and MainServerHandler.securityDateFormatter has no callers.
- **Small pre-existing oddities.** PodcastViewController registers a NoSearchResultsCell nib that
  does not exist (never dequeued, so harmless). The "Add podcast by URL" option asks for an "add"
  icon that is not in any catalog, so it shows without an icon. The acknowledgements page has not
  been checked against the libraries actually in the app.
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
   deletable and was not, until the screens built on it were replaced; then it was. Recompute
   the closure each time instead of trusting an old one.
8. **"The code exists" is not "the user can reach it."** Every claim about runtime behavior must
   be traced to an actual UI trigger or lifecycle event, not inferred from a grep hit. Three
   separate wrong findings in the server audit came from skipping this. Trace sinks upward to a
   real entry point, and prefer testing the app over reading the code.
9. **Nested types inside extensions are declarations too.** URL+Throwing.swift looked dead (its
   init(throwing:) had no live callers) but PodHopperSearch throws URL.URLCreationError, which
   that file declares. Check every name a file declares, including types nested in extensions.
10. **An image name that matches a strings key is not a use.** Several unused images shared names
   with localization keys (discover_popular, about_website). Asset usage scans must ignore
   .strings files.
