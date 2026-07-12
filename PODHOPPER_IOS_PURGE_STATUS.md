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
OPML export builds its uuid to feed url mapping on device. Verified: zero calls to any
Pocket Casts network handler remain in the app.

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

## Remaining cleanup (none urgent, nothing user facing)

- **Dead menu in the legal web view.** OnlineSupportController creates customRightBtn (a "..."
  menu with Connection Status, Export Database, and Logs) but never assigns it to
  navigationItem.rightBarButtonItem, so it never renders. That makes LogsView, LogsViewController,
  StatusPageView, and StatusPageViewModel unreachable dead code. Delete the menu and those
  screens together.
- **Zendesk.** ZendeskSupportService and the message support stack have no reachable presenter
  (EmailHelper, their only caller, has zero callers). Deletable.
- **Vestigial Pocket Casts constants.** The service host functions in ServerConstants (main,
  api, cache, discover, image, files, share, lists, search, generatedTranscripts) now have no
  live callers. The Fingerprint subsystem also has no reachable trigger.
- **addFromiTunesId** still points at the Pocket Casts server, but no live flow reaches it
  (Discover resolves iTunes entries to feed urls before opening a podcast page). Dead by flow,
  not by code.
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
