import XCTest

@testable import PocketCastsUtils

final class IntSafeDoubleTests: XCTestCase {
    func testOrdinaryValuesConvertLikeInt() {
        XCTAssertEqual(Int(safeDouble: 12.9), 12)
        XCTAssertEqual(Int(safeDouble: -12.9), -12)
        XCTAssertEqual(Int(safeDouble: 0), 0)
    }

    func testValuesAnIntCanNotHoldBecomeZero() {
        XCTAssertEqual(Int(safeDouble: .nan), 0)
        XCTAssertEqual(Int(safeDouble: .infinity), 0)
        XCTAssertEqual(Int(safeDouble: -.infinity), 0)
        XCTAssertEqual(Int(safeDouble: 1e30), 0)
        XCTAssertEqual(Int(safeDouble: -1e30), 0)
        XCTAssertEqual(Int(safeDouble: Double(Int.max)), 0)
    }
}
