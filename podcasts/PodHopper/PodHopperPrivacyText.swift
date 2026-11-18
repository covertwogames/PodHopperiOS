import Foundation

/// PodHopper: the Privacy Policy, word for word as published at podhopper.app/privacy. This file is
/// generated from the same source as that page, so the two cannot differ by a typo. When the policy
/// changes, generate this file again instead of editing it by hand.
///
/// Each paragraph and bullet is written in Markdown: **bold** for the lead-in words and
/// [text](address) for the few links. `PodHopperPrivacyView` shows it.
enum PodHopperPrivacyText {
    static let title = "PodHopper Privacy Policy"
    static let lastUpdated = "November 17, 2026"

    enum Block {
        case paragraph(String)
        case bullet(String)
    }

    struct Section {
        let heading: String
        let blocks: [Block]
    }

    /// The opening paragraphs, before the first numbered section.
    static let intro: [String] = [
        "This policy explains what information PodHopper handles, why, and the choices you have. PodHopper is made by Cover Two Strategies LLC, doing business as Cover Two Games (\"we\", \"us\" or \"our\"). The policy covers the PodHopper apps for phones, tablets, watches and vehicles, our website at podhopper.app, and the sync service behind them."
    ]

    static let sections: [Section] = [
        Section(
            heading: "1. The short version",
            blocks: [
                .bullet("PodHopper shows no ads of its own, and has no ad tracking and no analytics or usage tracking."),
                .bullet("We do not sell your information, and we do not share it for advertising."),
                .bullet("You can use PodHopper without an account. If you do, the app sends us nothing about you or what you listen to."),
                .bullet("If you create an account, we store what is needed to keep your devices in sync and your account secure."),
                .bullet("You can delete your account, and what we hold with it, at any time.")
            ]
        ),
        Section(
            heading: "2. Using PodHopper without an account",
            blocks: [
                .paragraph("Everything stays on your device: your subscriptions, your Up Next queue, your listening history and progress, your downloads, your settings and your listening statistics. None of it is sent to us."),
                .paragraph("Your device still connects to podcast publishers and to a podcast directory in order to find and play podcasts. Section 6 explains what they receive.")
            ]
        ),
        Section(
            heading: "3. What we store when you have an account",
            blocks: [
                .paragraph("**Your account details.** Your email address and a password. Our sign-in provider stores the password in scrambled (hashed) form, so we cannot read it. We use your email address to sign you in, to confirm your account, to reset your password, and to tell you about your account or about important changes to the service."),
                .paragraph("**What you sync.** So that your devices stay in step, we store:"),
                .bullet("your podcast subscriptions, as the feed address of each podcast;"),
                .bullet("your progress in each episode you have played: which episode and podcast it is, how far in you are, how long it is, whether you have finished it, and when that last changed; and"),
                .bullet("your Up Next queue: the episodes in it, with their titles and addresses."),
                .paragraph("Your progress and your queue also carry a random id and the model name of the device that last changed them, which is how sync works out which device is newest."),
                .paragraph("**Your signed-in devices.** For each device signed in to your account we store what kind of device it is (phone, tablet, car or watch), its model, the app version, when it signed in and when it was last active, and a random id the app made for that install. Our sign-in provider also records the IP address and the app and system version used each time a device signs in or renews its sign-in. We use this to show you your list of signed-in devices, to let you sign a device out, and to protect accounts from misuse. Devices running an older version of the app report less."),
                .paragraph("When you sign a device out from that list, we keep that install's random id, with nothing else attached to it, so the device can find out it was removed and clear what it stored."),
                .paragraph("**Codes for signing in a car or watch.** A car or watch signs in by showing a short code that you enter on your phone. We store the code, the model name of the device that asked for it, and when it expires. A code stops working after ten minutes."),
                .paragraph("**Your agreement to our Terms.** The version of the Terms of Service you agreed to, when you agreed, the kind of device and app version you were using, and how you agreed, for example by ticking the box when you created your account."),
                .paragraph("**Diagnostic logs, only if you send one.** The apps keep an activity log on your device to help find problems. It never leaves your device without your say-so. If you choose the option in the app to share or upload logs, that log is sent to us. It can include the podcasts and episodes you played, playback and sync activity, error messages, and technical details such as your device model, system version and app version. It is stored privately under your account and used only to investigate problems."),
                .paragraph("**Messages you send us.** If you email us, we keep your message and address so we can reply and keep a record."),
                .paragraph("**Our website.** When you visit podhopper.app, the company that hosts the site receives the usual technical details of any web visit, such as your IP address and browser type, in order to deliver the pages.")
            ]
        ),
        Section(
            heading: "4. What stays on your device",
            blocks: [
                .paragraph("Your listening statistics, the charts and totals on your stats page, are worked out and kept on your device only. So are your downloaded episodes, your app settings, your search history, your filters and folders, and any files you add yourself. None of these are sent to us."),
                .paragraph("PodHopper does not collect your location, your contacts, or information from your vehicle such as your speed or where you drive.")
            ]
        ),
        Section(
            heading: "5. How we use what we store",
            blocks: [
                .bullet("**To run the service you asked for:** keeping your account working and your devices in sync."),
                .bullet("**To keep the service safe and working:** protecting accounts, preventing misuse, and finding and fixing problems."),
                .bullet("**To keep a record:** that you agreed to our Terms, and of what we said to each other if you contacted us."),
                .bullet("**To meet legal obligations** that apply to us."),
                .paragraph("We do not use your information for advertising, and we do not build a profile of you."),
                .paragraph("If you live somewhere that requires a legal basis for this, ours are: carrying out our agreement with you (your account and sync), our legitimate interest in running a safe and reliable service (security, troubleshooting and records), your consent (diagnostic logs, which are sent only when you choose to send them), and compliance with the law.")
            ]
        ),
        Section(
            heading: "6. Who else receives information",
            blocks: [
                .paragraph("**Our hosting provider.** The sync service runs on Supabase, a cloud database and sign-in provider, on servers in the United States. Supabase stores the information in Section 3 for us and sends the account emails, such as the one that resets your password. It acts on our instructions as our service provider."),
                .paragraph("**Podcast publishers.** PodHopper does not make or host podcasts. When you follow, refresh, stream or download a podcast, or load its artwork, your device connects directly to that podcast's publisher and to the hosting, measurement and advertising companies it uses. As with any internet connection, they receive your IP address, the name and version of the app, and what was requested. Many use this to count downloads or to choose which ads to insert. This happens whether or not you have an account. We do not control it, and it is covered by their policies, not this one. Some publishers still serve their feeds or audio over connections that are not encrypted."),
                .paragraph("**The podcast directory.** Search and the top charts come from Apple's public podcast directory. When you search, your search words are sent to Apple. When you browse the charts, your region is. Apple also receives your IP address, as with any connection. We do not attach your PodHopper account to these requests."),
                .paragraph("**Casting.** If you cast from a phone or tablet to another device, Google's Cast service is used, and Google handles that connection under its own policy."),
                .paragraph("**App stores, device makers and networks.** The store you got PodHopper from, the maker of your phone, watch or vehicle, and your mobile network handle installs, updates and connections under their own policies. If you have chosen on your device to share diagnostics with them, they may show us combined statistics, such as how often the app crashed. Those reports do not identify you."),
                .paragraph("**When the law requires it.** We may disclose information if we are legally required to, or where it is needed to protect the rights, safety or property of our users, the public or ourselves."),
                .paragraph("**If PodHopper changes hands.** If the service is taken over by another company, your information may pass to it. It would remain covered by this policy unless you are told otherwise and given a choice."),
                .paragraph("We do not sell your information, and we do not share it with advertisers or data brokers.")
            ]
        ),
        Section(
            heading: "7. Where your information is kept",
            blocks: [
                .paragraph("Our servers are in the United States. If you live elsewhere, your information is transferred to and stored in the United States, where data protection laws may differ from the laws where you live.")
            ]
        ),
        Section(
            heading: "8. How long we keep it",
            blocks: [
                .bullet("**Your account, what you sync, your device list and your Terms record:** until you delete your account."),
                .bullet("**A sign-in:** until that device signs out or is signed out. We may also end sign-ins that have not been used for 60 days or longer."),
                .bullet("**Codes for a car or watch:** they stop working after ten minutes."),
                .bullet("**Diagnostic logs:** only as long as we need them to look into the problem. You can ask us to delete yours at any time."),
                .bullet("**Messages you send us:** as long as needed to deal with your request and keep a record of it."),
                .paragraph("Routine backups kept by our hosting provider can hold a copy for a short time longer.")
            ]
        ),
        Section(
            heading: "9. Deleting your account and other choices",
            blocks: [
                .paragraph("**Deleting your account.** You can delete your account at any time in the app's settings or at [covertwogames.com/podhopperdeleteaccount.html](https://covertwogames.com/podhopperdeleteaccount.html). Deleting it permanently removes your account, what you sync, your list of signed-in devices and your Terms record from our servers."),
                .paragraph("Diagnostic logs you sent us are stored separately. Tell us when you delete your account, or at any other time, and we will delete those too."),
                .paragraph("What is stored on your own devices stays there until you clear it or remove the app. A car or watch clears what it stored when it is signed out."),
                .paragraph("**Other choices.** You can use PodHopper without an account. You can sign any device out of your account from the list of signed-in devices. You never have to send a diagnostic log. You can export your subscriptions from the app at any time.")
            ]
        ),
        Section(
            heading: "10. Your rights",
            blocks: [
                .paragraph("Depending on where you live, you may have the right to ask for a copy of the information we hold about you, to have it corrected or deleted, to receive it in a portable form, to object to or limit how we use it, and to withdraw a consent you gave. You may also have the right to complain to your local data protection authority."),
                .paragraph("To use any of these rights, email [feedback@podhopper.app](mailto:feedback@podhopper.app) from the address on your account. We will answer within the time the law requires, and we will not treat you differently for asking."),
                .paragraph("We do not sell or share personal information as those terms are used in California law. Because we do not track you across apps or websites, there is nothing for a Do Not Track or Global Privacy Control signal to switch off.")
            ]
        ),
        Section(
            heading: "11. Children",
            blocks: [
                .paragraph("PodHopper is not directed at children under 13, and we do not knowingly collect their personal information. If you believe a child under 13 has created an account, email us and we will delete it. Our Terms of Service set the minimum age for an account.")
            ]
        ),
        Section(
            heading: "12. Security",
            blocks: [
                .paragraph("Connections between the apps and our service are encrypted. Passwords are stored only in hashed form. Each account can reach only its own information on our servers, and our hosting provider encrypts what it stores. The sign-in for each device is kept in the app's private storage on that device."),
                .paragraph("No system is perfectly secure, which is one reason we collect so little. If you think someone else has access to your account, tell us right away. If we learn of a breach that affects your information, we will tell you as the law requires.")
            ]
        ),
        Section(
            heading: "13. Changes to this policy",
            blocks: [
                .paragraph("If this policy changes, we will post the new version here and update the date at the top. If a change is important, we will tell you in the app or by email before it takes effect.")
            ]
        ),
        Section(
            heading: "14. Contact us",
            blocks: [
                .paragraph("Cover Two Strategies LLC, doing business as Cover Two Games"),
                .paragraph("230 N. Washington Sq., Suite 101, Lansing, MI 48933"),
                .paragraph("Email: [feedback@podhopper.app](mailto:feedback@podhopper.app)")
            ]
        )
    ]
}
