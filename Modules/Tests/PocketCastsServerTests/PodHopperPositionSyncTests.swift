import XCTest
@testable import PocketCastsServer

/// Tests the pure apply decision at the heart of the position sync: the currently-playing guard
/// (never overwrite the episode playing right now), completion detection, and the
/// position-versus-in-progress branch. Conflict resolution is freshest-writer-wins decided by the
/// query, so the decision no longer takes any local timestamp. No database or player is involved.
final class PodHopperPositionSyncTests: XCTestCase {

    private typealias Decision = PodHopperPositionSync.ApplyDecision

    private func decide(
        playingThis: Bool = false,
        position: Int = 100,
        total: Int = 1000,
        completed: Bool = false,
        notPlayed: Bool = false
    ) -> Decision {
        PodHopperPositionSync.decideApply(
            isCurrentlyPlayingThisEpisode: playingThis,
            positionSec: position,
            totalSec: total,
            completed: completed,
            playingStatusIsNotPlayed: notPlayed
        )
    }

    func testCurrentlyPlayingEpisodeIsNeverOverwritten() {
        XCTAssertEqual(decide(playingThis: true, position: 50), .skip)
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

    func testIsCompletionRowHelper() {
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 0, totalSec: 0, completed: true))
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 500, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 0, completed: false))
    }
}
