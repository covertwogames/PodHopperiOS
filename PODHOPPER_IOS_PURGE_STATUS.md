# PodHopper iOS purge status and remaining work

State after purge waves 1-4 (July 2026). This is the map for finishing the dead-code cleanup
and the rules that prevent repeating the mistakes the first four waves already paid for.

## Completed (waves 1-4)

Deleted and verified: Tracks/CrashLogging/LiveAnalyticsStreamer adapters, the phone and watch
Sentry error loggers, Sonos linking, Pocket Casts list sharing (in and out), BackgroundSyncManager
and its PC refresh requests, the whole Referrals program, the pca.st shared item import chain,
the Ratings cluster, the Kids Profile cluster, the Blaze ad machinery, and every End of Year
entry point plus its two orphan views. Roughly 50 files gone; every deletion verified by symbol
extraction, member-level caller scan, and project-registration check before delivery.

## End of Year: refactor, not purge (wave 4 finding)

The EOY trees (podcasts/End of Year, Modules/Sources/EndOfYear, the sync task, EndOfYear.xcassets)
are NOT deletable. The onboarding intro carousel, login cover art, WhatsNew views, and
ServerPodcastManager are built on the EOY stories engine and its shared components
(dependency closure: 55 of 58 app files load-bearing; Analytics track(_:story:) has 57 callers).
Everything is unreachable (entry points severed, flags off, sync login-gated) but load-bearing.
Deleting requires first extracting the stories engine and shared views into their own module.

## Wave 5: Pocket Casts account screens (not started)

AccountViewController and detail cells, SyncSigninViewController, NewEmailViewController,
ChangeEmail/ChangePasswordViewController, LoginCoordinator PC paths, GoogleSocialLogin,
SocialLoginFactory, the Zendesk composer stack, CancelSubscription flow, Plus upsell screens
(UpgradeCard, UpgradeProducts, paywall onboarding). Entangled with OnboardingFlow; expect
heavy edit-before-delete surgery like waves 2-4.

## Xcode-side finale (do on the Mac with the compiler live)

- SPM packages: Firebase, Automattic-Tracks-iOS, Sentry, GoogleSignIn (remove from
  Modules/Package.swift xcodeTarget blocks and resolve fallout in Xcode)
- "Pocket Casts TV App" target and directory (never built; full PC code)
- App Clip target remnants
- The api()/sharing()/lists()/files() host functions in ServerConstants, only after wave 5

## Process rules (each one paid for in build errors)

1. NEVER use the pbxproj python library's save on this project. Prior sessions added files with
   custom non-hex IDs (the four ListeningHeatmap entries); the library quotes them on rewrite,
   silently breaking their target membership, and it strips synchronized-folder lines. Text-anchored
   line surgery only, with an enumerated expected-removal count.
2. Before deleting any file, check whether it is project-registered (grep the pbxproj for the
   filename) or folder-synchronized. Registered files need their PBXBuildFile, PBXFileReference,
   group child, and build-phase lines removed. Watch for sibling .xcassets catalogs registered
   separately (Referrals and KidsProfile both had one).
3. Verification is three scans, all before delivery: (a) extract every symbol the doomed files
   declare from their actual contents and grep the live tree; (b) after edits, scan every member
   the edits removed for surviving callers; (c) ID-agnostic dangling-reference scan on the pbxproj
   (no 24-hex assumption). Generic names (Constants, State, track, id) need per-hit inspection,
   not pattern exclusion.
4. Feature clusters can export shared components. Compute the dependency closure before
   committing to a deletion scope; EOY looked deletable and was not.

## Not deletable (verified in use)

- OnlineSupportController: the WebView behind Legal and More
- Int.pollWaitingTime in PodcastSearchTask.swift: used by ServerPodcastManager and
  PodcastSearchOperation
- FirebaseManager stub and the credentials generation script: until the SPM packages go
- Analytics+story.swift and the EOY trees per above
