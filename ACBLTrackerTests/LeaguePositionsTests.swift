import XCTest
@testable import ACBLTracker

final class LeaguePositionsTests: XCTestCase {
    private func player(_ name: String, _ team: String, espn: String = "PG") -> DirectoryPlayer {
        DirectoryPlayer(id: name, name: name, teamID: "1", teamAbbr: team, position: espn, headshot: nil)
    }

    private let positions = LeaguePositions(text: """
    # comment lines and blanks are skipped

    NOP|C|Zion Williamson
    CHI|C|Nic Claxton;Jalen Smith
    GSW|G|Stephen Curry
    CLE|C|Ernest Udeh, Jr.
    """)

    func testLeaguePositionBeatsESPN() {
        let zion = player("Zion Williamson", "NO", espn: "PF")
        XCTAssertEqual(positions.position(for: zion), .C)
        XCTAssertEqual(positions.resolved(for: zion), .C)
    }

    func testNameMatchIgnoresAccentsSuffixesAndPunctuation() {
        XCTAssertEqual(positions.position(for: player("Ernest Udeh Jr.", "CLE")), .C)
    }

    func testSameLastNameOnSameTeamCoversNicknames() {
        // The sheet says "Nic", ESPN says "Nicolas".
        XCTAssertEqual(positions.position(for: player("Nicolas Claxton", "CHI")), .C)
        // Sheet team GSW is ESPN's GS.
        XCTAssertEqual(positions.position(for: player("Steph Curry", "GS")), .G)
    }

    func testLastNameOnAnotherTeamDoesNotMatch() {
        XCTAssertNil(positions.position(for: player("Nicolas Claxton", "BKN")))
    }

    func testUnlistedPlayerFallsBackToESPN() {
        let p = player("Nobody Real", "NYK", espn: "SG")
        XCTAssertNil(positions.position(for: p))
        XCTAssertEqual(positions.resolved(for: p), .G)
    }

    /// Catches a typo in the bundled file.
    func testBundledFileLoads() {
        let bundled = LeaguePositions.bundled
        XCTAssertEqual(bundled.position(for: player("Jalen Brunson", "NY")), .G)
        XCTAssertEqual(bundled.position(for: player("Kevin Durant", "HOU")), .F)
        XCTAssertEqual(bundled.position(for: player("Zion Williamson", "NO")), .C)
    }
}
