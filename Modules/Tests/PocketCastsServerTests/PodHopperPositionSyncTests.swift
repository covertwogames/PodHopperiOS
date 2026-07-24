import XCTest
@testable import PocketCastsServer

/// Tests the pure apply decision at the heart of the position sync: the currently-playing guard
/// (never overwrite the episode playing right now), completion detection, un-completion when another
/// device un-marks a finished episode, and the position-versus-in-progress branch. Conflict
/// resolution is freshest-writer-wins, decided by the query and by the staleness guard in the
/// caller, so the decision itself takes no timestamp. No database or player is involved.
final class PodHopperPositionSyncTests: XCTestCase {

    private typealias Decision = PodHopperPositionSync.ApplyDecision

    private func decide(
        playingThis: Bool = false,
        position: Int = 100,
        total: Int = 1000,
        completed: Bool = false,
        notPlayed: Bool = false,
        completedLocally: Bool = false
    ) -> Decision {
        PodHopperPositionSync.decideApply(
            isCurrentlyPlayingThisEpisode: playingThis,
            positionSec: position,
            totalSec: total,
            completed: completed,
            playingStatusIsNotPlayed: notPlayed,
            playingStatusIsCompleted: completedLocally
        )
    }

    func testCurrentlyPlayingEpisodeIsNeverOverwritten() {
        XCTAssertEqual(decide(playingThis: true, position: 50), .skip)
    }

    func testCurrentlyPlayingEpisodeIsNotRegressedEither() {
        XCTAssertEqual(decide(playingThis: true, position: 0, completed: false, completedLocally: true), .skip)
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

    /// An un-mark row carries position zero. It must not flip an already-unplayed episode to
    /// in-progress, which would show phantom progress on an episode nobody has started.
    func testPositionZeroDoesNotMarkAnUnplayedEpisodeInProgress() {
        XCTAssertEqual(decide(position: 0, total: 1000, notPlayed: true), .setPosition(0, markInProgress: false))
    }

    /// Another device un-marked an episode this device had finished. The row wins and the episode
    /// regresses. The caller applies the staleness guard before this decision is reached.
    func testUnMarkRowRegressesALocallyCompletedEpisode() {
        XCTAssertEqual(decide(position: 0, total: 1000, completed: false, completedLocally: true), .uncomplete(0))
    }

    /// A regression that also carries progress hands the position back, so the episode resumes where
    /// the other device left it rather than at zero.
    func testUnMarkRowWithProgressCarriesThePosition() {
        XCTAssertEqual(decide(position: 240, total: 1000, completed: false, completedLocally: true), .uncomplete(240))
    }

    /// A completion row for an episode already finished here is still a completion, not a
    /// regression. The reconcile skips it as a no-op via its own already-completed check.
    func testCompletionRowOnALocallyCompletedEpisodeIsStillCompletion() {
        XCTAssertEqual(decide(completed: true, completedLocally: true), .complete)
    }

    func testNegativePositionWithoutCompletionIsSkipped() {
        XCTAssertEqual(decide(position: -1, total: 0, completed: false), .skip)
    }

    func testIsCompletionRowHelper() {
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 0, totalSec: 0, completed: true))
        XCTAssertTrue(PodHopperPositionSync.isCompletionRow(positionSec: 500, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 500, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 100, totalSec: 0, completed: false))
        XCTAssertFalse(PodHopperPositionSync.isCompletionRow(positionSec: 0, totalSec: 1000, completed: false))
    }
}
