# PodHopper

A privacy-first podcast player for iOS and Apple Watch.

PodHopper is an independent fork of [Pocket Casts](https://github.com/Automattic/pocket-casts-ios), the podcast app open-sourced by Automattic. It keeps the parts that make a great listening app and strips out the parts that watch you. No ads, no analytics, no usage tracking. It is built and maintained by Cover Two Strategies LLC, doing business as Cover Two Games.

## What makes it different

- **No tracking.** The inherited third-party analytics trackers have been removed. Nothing about how you use the app is transmitted anywhere.
- **No ads.** There is no advertising and no ad tracking.
- **Local by default.** Your listening stats are calculated and kept on your device.
- **Sync that stays out of your way.** Sign in once and your subscriptions, your queue, and the exact spot you paused follow you from device to device. Start an episode on your phone, pick it up on your watch, and it is right where you left it. That synced information is used for one thing only, keeping your devices in step.

See the in-app privacy policy or [podhopper.app](https://podhopper.app) for the full details.

## Building

PodHopper is a standard Xcode project written in Swift. Its shared code is organized as a local Swift Package in `Modules/`.

Requirements:

- Xcode (latest stable)
- iOS deployment target 17.0

To build:

1. Clone the repository.
2. Open `podcasts.xcodeproj` in Xcode.
3. Let Xcode resolve the Swift Package dependencies.
4. Select the `podcasts` scheme and press Run. The `Pocket Casts Watch App` scheme builds the companion Apple Watch app.

## Roadmap

- **Apple Watch.** Sign the watch into your account with a pairing code and it pulls your library and plays on its own, no phone needed.
- **CarPlay.** Carrying that same effortless handoff straight into your dashboard, so the episode you started in the kitchen is already cued up when you start the car. CarPlay support is built into the app and is pending Apple's CarPlay audio entitlement approval.

## Privacy

PodHopper is built to collect as little as possible. The short version: it does not track you, show ads, run analytics, or sell or share your information. The only information it handles is what is needed to sync your podcasts between your own devices. Full policy: [podhopper.app](https://podhopper.app).

## License

PodHopper is based on Pocket Casts by Automattic and is distributed under the Mozilla Public License 2.0 (MPL-2.0). The full license text is in [LICENSE.md](LICENSE.md).

Original Pocket Casts code is Copyright Automattic, Inc. New PodHopper code is Copyright Cover Two Strategies LLC.

Pocket Casts is a trademark of Automattic, Inc. PodHopper is an independent project and is not affiliated with, sponsored by, or endorsed by Automattic.

## Contact

Questions or feedback: info@covertwogames.com
