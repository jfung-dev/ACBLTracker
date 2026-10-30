import XCTest
@testable import ACBLTracker

final class DateParsingTests: XCTestCase {
    func testScoreboardStyleDate() {
        XCTAssertNotNil(DateParsing.parse("2026-10-21T23:30Z"))
    }

    /// The game log endpoint sends fractional seconds and a numeric offset, not a trailing Z.
    func testGameLogStyleDate() {
        let d = DateParsing.parse("2026-10-17T02:30:00.000+00:00")
        XCTAssertEqual(d, DateParsing.parse("2026-10-17T02:30Z"))
    }
}
