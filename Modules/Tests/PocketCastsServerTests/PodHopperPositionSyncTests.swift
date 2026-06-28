import XCTest
@testable import PocketCastsServer

/// Tests the pure apply decision at the heart of the position sync: the two protections (never apply
/// a stale remote change, never overwrite the episode playing right now), completion detection, and
/// the position-versus-in-progress branch. No database or player is involved.
final class PodHopperPositionSyncTests: XCTestCase {

    private typealias Decision = PodHopperPositionSync.ApplyDecision

    private func decide(
        localModified: Int64 = 0,
        playingThis: Bool = false,
        position: Int = 100,
        total: Int = 1000,
        completed: Bool = false,
        remoteTs: Int64 = 500,
        notPlayed: Bool = false
    ) -> Decision {
        PodHopperPositionSync.decideApply(
            localModifiedMs: localModified,
            isCurrentlyPlayingThisEpisode: playingThis,
            positionSec: position,
            totalSec: total,
            completed: completed,
            remoteTs: remoteTs,
            playingStatusIsNotPlayed: notPlayed
        )
    }

    func testStaleRemoteChangeIsSkipped() {
        // Local change is newer than the remote row, so the remote must not rewind us.
        XCTAssertEqual(decide(localModified: 600, remoteTs: 500), .skip)
    }

    func testStaleWinsEvenOverACompletion() {
        // A stale completion must not undo newer local progress.
        XCTAssertEqual(decide(localModified: 600, completed: true, remoteTs: 500), .skip)
    }

    func testCurrentlyPlayingEpisodeIsNeverOverwritten() {
        XCTAssertEqual(decide(playingThis: true, position: 50, remoteTs: 9000), .skip)
    }

    func testExplicitCompletionMarksPlayed() {
        XCTAssertEqual(decide(completed: true), .complete)
    }

    func testPositionPastEndCountsAsCompletion() {
        XCTAssertEqual(decide(position: 1000, total: 1000, completed: false), .complete)
    }

    func testInProgressPositionFromNotPlayedAlsoMarksInProgress() {
        XCTAssertEqual(decide(position: 120, total: 1000, notPlayed: true), .setPosition(120, markInProgress: true))
    }

    func testInProgressPositionFromInProgressDoesNotTouchStatus() {
        XCTAssertEqual(decide(position: 120, total: 1000, notPlayed: false), .setPosition(120, markInProgress: false))
    }

    func testNegativePositionWithoutCompletionIsSkipped() {
        XCTAssertEqual(decide(position: -1, total: 0, completed: false), .skip)
    }

    func testEqualLocalModifiedIsNotStale() {
        // Equal timestamps are allowed through (Guard 1 only blocks strictly older remote rows).
        XCTAssertEqual(decide(localModified: 500, position: 200, total: 1000, remoteTs: 500), .setPosition(200, markInProgress: false))
    }

    func testIsCompletionRowHelper() {
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 0, totalSec: 0, completed: true))
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 500, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 0, completed: false))
    }
}
