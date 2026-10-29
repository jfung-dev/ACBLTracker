import XCTest
@testable import ACBLTracker

final class LeagueRostersTests: XCTestCase {
    private let json = """
    {
      "weeks": {
        "2026-10-20": { "sheet": "W1", "teams": [ { "name": "A", "players": ["Jalen Brunson|NYK"] } ] },
        "2026-10-27": { "sheet": "W2", "teams": [ { "name": "B", "players": ["Kennedy Chandler|", " Ja Morant | POR "] } ] }
      }
    }
    """

    private func rosters() throws -> LeagueRosters {
        try JSONDecoder().decode(LeagueRosters.self, from: Data(json.utf8))
    }

    func testEntriesSplitNameAndTeam() throws {
        let week = try XCTUnwrap(try rosters().weeks["2026-10-27"])
        let entries = LeagueRosters.entries(in: week)
        XCTAssertEqual(entries.map(\.name), ["Kennedy Chandler", "Ja Morant"])
        XCTAssertEqual(entries.map(\.team), ["", "POR"])
        XCTAssertEqual(Set(entries.map(\.owner)), ["B"])
    }

    func testSnapshotFallsBackToEarlierWeek() throws {
        let r = try rosters()
        XCTAssertEqual(r.snapshot(for: "2026-10-27")?.week.sheet, "W2")
        XCTAssertEqual(r.snapshot(for: "2026-11-03")?.week.sheet, "W2")
        XCTAssertEqual(r.snapshot(for: "2026-10-20")?.week.sheet, "W1")
        XCTAssertNil(r.snapshot(for: "2026-10-13"))
    }

    /// Catches a typo in the bundled file: every team in every week lists a full 14-man roster.
    func testBundledFileHasFullRosters() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "LeagueRosters", withExtension: "json"))
        let r = try JSONDecoder().decode(LeagueRosters.self, from: Data(contentsOf: url))
        XCTAssertFalse(r.weeks.isEmpty)
        for (key, week) in r.weeks {
            for team in week.teams {
                XCTAssertEqual(team.players.count, 14, "\(team.name) in \(key)")
            }
        }
    }
}
