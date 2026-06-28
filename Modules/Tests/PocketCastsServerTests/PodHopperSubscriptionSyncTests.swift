import XCTest
@testable import PocketCastsServer

/// Tests the pure reconciliation at the heart of the subscription sync: what to apply locally, what
/// to upload, and the new cursor, given remote rows and the local state. This is where echo
/// prevention and first-sync behaviour live, so it is pinned here with no network or database.
final class PodHopperSubscriptionSyncTests: XCTestCase {

    private typealias Plan = PodHopperSubscriptionSync.SyncPlan
    private func row(_ feed: String, _ subscribed: Bool, _ ts: Int64) -> (feedUrl: String, subscribed: Bool, updatedAtMs: Int64) {
        (feed, subscribed, ts)
    }

    func testFirstSyncUploadsWholeLocalLibrary() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 0,
            localSubscriptions: ["a", "b", "c"],
            remoteRows: [],
            queuedAdded: [],
            queuedRemoved: []
        )
        XCTAssertEqual(plan.addsToUpload, ["a", "b", "c"]) // first sync seeds the cloud
        XCTAssertTrue(plan.toSubscribe.isEmpty)
        XCTAssertTrue(plan.toUnsubscribe.isEmpty)
        XCTAssertTrue(plan.removesToUpload.isEmpty)
        XCTAssertEqual(plan.newestCursor, 0)
    }

    func testNonFirstSyncUploadsOnlyQueuedAdds() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 100,
            localSubscriptions: ["a", "b", "c"],
            remoteRows: [],
            queuedAdded: ["c"],
            queuedRemoved: []
        )
        XCTAssertEqual(plan.addsToUpload, ["c"]) // not the whole library, just the queued change
    }

    func testRemoteAddAppliedUnlessLocalOrJustRemoved() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 100,
            localSubscriptions: ["have"],
            remoteRows: [row("new", true, 150), row("have", true, 160), row("justremoved", true, 170)],
            queuedAdded: [],
            queuedRemoved: ["justremoved"]
        )
        XCTAssertEqual(plan.toSubscribe, ["new"]) // "have" already local, "justremoved" queued for removal
        XCTAssertEqual(plan.newestCursor, 170)
    }

    func testRemoteRemoveAppliedUnlessJustResubscribed() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 100,
            localSubscriptions: [],
            remoteRows: [row("gone", false, 200), row("kept", false, 210)],
            queuedAdded: ["kept"],
            queuedRemoved: []
        )
        XCTAssertEqual(plan.toUnsubscribe, ["gone"]) // "kept" was just re-subscribed locally, so do not remove it
        XCTAssertEqual(plan.newestCursor, 210)
    }

    func testEchoOfOwnAddIsNotReuploaded() {
        // Our own subscribe to "x" was uploaded last pass and now comes back as a remote add.
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 100,
            localSubscriptions: ["x"],
            remoteRows: [row("x", true, 300)],
            queuedAdded: ["x"],
            queuedRemoved: []
        )
        XCTAssertFalse(plan.addsToUpload.contains("x")) // not re-uploaded
        XCTAssertFalse(plan.toSubscribe.contains("x"))  // not re-applied (already local)
        XCTAssertEqual(plan.newestCursor, 300)          // cursor moves past it
    }

    func testEchoOfOwnRemoveIsNotReuploaded() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 100,
            localSubscriptions: [],
            remoteRows: [row("y", false, 300)],
            queuedAdded: [],
            queuedRemoved: ["y"]
        )
        XCTAssertFalse(plan.removesToUpload.contains("y")) // not re-uploaded
        XCTAssertEqual(plan.newestCursor, 300)
    }

    func testCursorIsHighestUpdatedAtSeen() {
        let plan = PodHopperSubscriptionSync.reconcile(
            lastSync: 5,
            localSubscriptions: [],
            remoteRows: [row("a", true, 40), row("b", true, 90), row("c", false, 70)],
            queuedAdded: [],
            queuedRemoved: []
        )
        XCTAssertEqual(plan.newestCursor, 90)
    }
}
